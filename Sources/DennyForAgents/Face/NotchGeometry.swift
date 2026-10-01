import CoreGraphics

/// Raw inputs read from a single `NSScreen`, captured as a plain value type so
/// the placement math below has no AppKit dependency and can be unit-tested
/// without a real display attached.
///
/// `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` are the two public AppKit
/// regions flanking a physical camera notch (`nil` on displays/macOS versions
/// that don't report them). `safeAreaInsetsTop` mirrors
/// `NSScreen.safeAreaInsets.top`.
///
/// Per the Denny Notch Hub plan, `safeAreaInsets.top` alone does not prove the
/// notch WIDTH -- it is a vertical inset, not a horizontal measurement -- so
/// it is treated here only as a secondary, vertical-only signal. The primary
/// width candidate is the gap between the two auxiliary areas.
public struct NotchGeometryInput: Equatable {
    public var screenFrame: CGRect
    public var auxiliaryTopLeftArea: CGRect?
    public var auxiliaryTopRightArea: CGRect?
    public var safeAreaInsetsTop: CGFloat

    public init(
        screenFrame: CGRect,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?,
        safeAreaInsetsTop: CGFloat
    ) {
        self.screenFrame = screenFrame
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
        self.safeAreaInsetsTop = safeAreaInsetsTop
    }
}

/// User-facing manual correction, stored separately from whatever the OS
/// reports -- never merged into a single "final" number, so a fresh OS
/// reading (e.g. after a macOS update changes what it reports) never silently
/// discards the user's own calibration.
public struct NotchFineTune: Equatable {
    public var widthAdjustment: CGFloat
    public var heightAdjustment: CGFloat
    public var horizontalOffset: CGFloat

    public init(widthAdjustment: CGFloat = 0, heightAdjustment: CGFloat = 0, horizontalOffset: CGFloat = 0) {
        self.widthAdjustment = widthAdjustment
        self.heightAdjustment = heightAdjustment
        self.horizontalOffset = horizontalOffset
    }

    public static let zero = NotchFineTune()
}

public struct NotchGeometryResult: Equatable {
    /// True when *any* notch signal was found (auxiliary-area gap or a
    /// non-zero safe-area top inset) -- not just the auxiliary areas.
    public var hasPhysicalNotch: Bool
    /// True when no notch signal was found at all and the fixed capsule
    /// fallback was used instead (external display, non-notch Mac, or a
    /// future OS that stops reporting these APIs).
    public var isFallbackCapsule: Bool
    public var rawWidth: CGFloat
    public var rawTopInset: CGFloat
    public var width: CGFloat
    public var verticalExtent: CGFloat
    /// Resting ("closed") frame, in the screen's own coordinate space.
    public var closedFrame: CGRect
}

public enum NotchGeometry {
    /// Capsule used when the target screen reports no notch signal at all --
    /// matches the Windows / no-notch-Mac capsule fallback from the plan.
    public static let fallbackCapsuleWidth: CGFloat = 190
    public static let fallbackCapsuleHeight: CGFloat = 32

    /// Sanity floor so a pathological fine-tune value (e.g. a large negative
    /// widthAdjustment) can never collapse the surface to zero/negative size.
    public static let minWidth: CGFloat = 80
    public static let minHeight: CGFloat = 20

    public static func compute(input: NotchGeometryInput, fineTune: NotchFineTune) -> NotchGeometryResult {
        var rawWidth: CGFloat = 0
        var hasNotchFromAux = false
        if let left = input.auxiliaryTopLeftArea, let right = input.auxiliaryTopRightArea {
            let gap = right.minX - left.maxX
            if gap > 0 {
                rawWidth = gap
                hasNotchFromAux = true
            }
        }

        let rawTopInset = max(0, input.safeAreaInsetsTop)
        let hasNotchSignal = hasNotchFromAux || rawTopInset > 0

        let baseWidth = hasNotchFromAux ? rawWidth : fallbackCapsuleWidth
        let baseHeight = rawTopInset > 0 ? rawTopInset : fallbackCapsuleHeight

        let width = max(minWidth, baseWidth + fineTune.widthAdjustment)
        let verticalExtent = max(minHeight, baseHeight + fineTune.heightAdjustment)

        let centerX = input.screenFrame.midX + fineTune.horizontalOffset
        let originX = centerX - width / 2
        let originY = input.screenFrame.maxY - verticalExtent
        let frame = CGRect(x: originX, y: originY, width: width, height: verticalExtent)

        return NotchGeometryResult(
            hasPhysicalNotch: hasNotchSignal,
            isFallbackCapsule: !hasNotchSignal,
            rawWidth: rawWidth,
            rawTopInset: rawTopInset,
            width: width,
            verticalExtent: verticalExtent,
            closedFrame: frame
        )
    }
}

/// Derives the nook/tray frames from the closed (resting) frame. The top
/// edge always stays flush with the screen's top edge -- matches the physical
/// camera notch -- so growth only ever extends width and downward height.
/// `dragging` reuses `tray`'s frame (see `HostController`) -- the drop-zone
/// lives inside the already-open tray, it isn't a separately-sized state.
public enum NotchSurfaceSizing {
    public struct Sizes: Equatable {
        public let closed: CGRect
        public let nook: CGRect
        public let tray: CGRect
        public let pomodoroNook: CGRect
        public let pomodoroTray: CGRect
    }

    public static func sizes(
        closed: CGRect,
        screenMaxY: CGFloat,
        nookWidthGrowth: CGFloat = 8,
        // The approved face uses a 190x145 canvas. This growth leaves enough
        // room for that canvas plus its one-line caption below the physical
        // camera housing, while remaining smaller than the expanded tray.
        nookHeightGrowth: CGFloat = 124,
        trayWidthGrowth: CGFloat = 570,
        trayHeightGrowth: CGFloat = 260,
        pomodoroNookWidthGrowth: CGFloat = 150,
        pomodoroNookHeightGrowth: CGFloat = 58,
        pomodoroTrayWidthGrowth: CGFloat = 570,
        pomodoroTrayHeightGrowth: CGFloat = 260
    ) -> Sizes {
        func grown(widthGrowth: CGFloat, heightGrowth: CGFloat) -> CGRect {
            let width = closed.width + widthGrowth
            let height = closed.height + heightGrowth
            let originX = closed.midX - width / 2
            let originY = screenMaxY - height
            return CGRect(x: originX, y: originY, width: width, height: height)
        }
        return Sizes(
            closed: closed,
            nook: grown(widthGrowth: nookWidthGrowth, heightGrowth: nookHeightGrowth),
            tray: grown(widthGrowth: trayWidthGrowth, heightGrowth: trayHeightGrowth),
            pomodoroNook: grown(
                widthGrowth: pomodoroNookWidthGrowth,
                heightGrowth: pomodoroNookHeightGrowth
            ),
            pomodoroTray: grown(
                widthGrowth: pomodoroTrayWidthGrowth,
                heightGrowth: pomodoroTrayHeightGrowth
            )
        )
    }
}
