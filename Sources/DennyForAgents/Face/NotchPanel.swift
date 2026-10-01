import AppKit

/// Borderless panel hosting the notch surface, always `.nonactivatingPanel`
/// -- this style mask lets the panel become KEY (receive keyboard events)
/// WITHOUT activating our app: the previously-frontmost app stays visually
/// active, its menu bar stays up. Whether it actually can become key is
/// dynamic (`allowsKeyWhileOpen`): false while closed (a click must never
/// steal focus), true only while the tray is open, so a local `NSEvent`
/// monitor can catch Escape to close it (see `HostController`). Never
/// becomes MAIN.
final class NotchPanel: NSPanel {
    var allowsKeyWhileOpen = false

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        // Match the working reference's primary borderless window level
        // (25) instead of placing the drop destination at screen-saver
        // level, far above ordinary status-bar UI.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { allowsKeyWhileOpen }
    override var canBecomeMain: Bool { false }
}
