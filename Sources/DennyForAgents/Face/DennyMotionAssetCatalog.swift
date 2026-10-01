import AppKit

struct DennyMotionHandImage {
    let image: NSImage
    let width: CGFloat
    let height: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
}

/// Crops the approved RGB-on-black hand sheets once. The renderer uses screen
/// blending against the notch's single black background, so black sheet
/// pixels never become a second rectangular panel.
final class DennyMotionAssetCatalog {
    static let shared = DennyMotionAssetCatalog()

    private struct Crop {
        let file: String
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let anchorX: Int
        let baselineY: Int
        let scale: CGFloat
    }

    private let resourceBundle: Bundle
    private var cache: [DennyFaceHandAsset: DennyMotionHandImage] = [:]

    private init() {
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .deletingLastPathComponent()
        // `swift build` leaves the resource bundle next to the binary; the
        // packaged .app keeps it in Contents/Resources. Check both, plus the
        // newer Contents/Resources layer inside the bundle itself.
        let searchDirectories = [executableDirectory, Bundle.main.resourceURL].compactMap { $0 }
        let siblingBundle = searchDirectories.lazy.compactMap { directory in
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ))?.first(where: { candidate in
                guard candidate.pathExtension == "bundle" else { return false }
                let markers = [
                    candidate.appendingPathComponent("DennyMotion/robot-hands-approved.png"),
                    candidate.appendingPathComponent("Contents/Resources/DennyMotion/robot-hands-approved.png")
                ]
                return markers.contains { FileManager.default.fileExists(atPath: $0.path) }
            })
        }.first.flatMap { Bundle(url: $0) }
        resourceBundle = siblingBundle ?? Bundle.module
    }

    var activityDirectory: URL? {
        resourceBundle.url(forResource: "DennyActivities", withExtension: nil)
    }

    func hand(_ asset: DennyFaceHandAsset) -> DennyMotionHandImage? {
        if let cached = cache[asset] { return cached }
        guard let crop = descriptor(for: asset) else { return nil }
        guard let url = resourceBundle.url(
            forResource: crop.file,
            withExtension: "png",
            subdirectory: "DennyMotion"
        ), let source = NSImage(contentsOf: url),
           let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let cropped = cgImage.cropping(to: CGRect(
               x: CGFloat(crop.x),
               y: CGFloat(crop.y),
               width: CGFloat(crop.width),
               height: CGFloat(crop.height)
           )) else { return nil }

        let width = CGFloat(crop.width) * crop.scale
        let height = CGFloat(crop.height) * crop.scale
        let result = DennyMotionHandImage(
            image: NSImage(
                cgImage: cropped,
                size: NSSize(width: CGFloat(crop.width), height: CGFloat(crop.height))
            ),
            width: width,
            height: height,
            offsetX: CGFloat(crop.x - crop.anchorX) * crop.scale + width / 2,
            offsetY: CGFloat(crop.y - crop.baselineY) * crop.scale + height / 2
        )
        cache[asset] = result
        return result
    }

    private func descriptor(for asset: DennyFaceHandAsset) -> Crop? {
        switch asset {
        case .open:
            return Crop(file: "robot-hands-approved", x: 135, y: 130, width: 495, height: 570, anchorX: 382, baselineY: 683, scale: 0.055)
        case .index:
            return Crop(file: "robot-hands-approved", x: 1240, y: 125, width: 370, height: 575, anchorX: 1444, baselineY: 683, scale: 0.055)
        case .fistLeft:
            return Crop(file: "robot-fists-white", x: 170, y: 230, width: 540, height: 610, anchorX: 510, baselineY: 680, scale: 0.052)
        case .fistRight:
            return Crop(file: "robot-fists-white", x: 820, y: 230, width: 540, height: 610, anchorX: 1026, baselineY: 680, scale: 0.052)
        case .hugLeft:
            return Crop(file: "robot-hug", x: 60, y: 150, width: 630, height: 690, anchorX: 320, baselineY: 790, scale: 0.038)
        case .hugRight:
            return Crop(file: "robot-hug", x: 850, y: 150, width: 630, height: 690, anchorX: 1216, baselineY: 790, scale: 0.038)
        case .shyLeft:
            return Crop(file: "robot-shy", x: 95, y: 195, width: 635, height: 630, anchorX: 295, baselineY: 775, scale: 0.042)
        case .shyRight:
            return Crop(file: "robot-shy", x: 805, y: 195, width: 635, height: 630, anchorX: 1241, baselineY: 775, scale: 0.042)
        case .thumb:
            // The approved storyboard requires a coherent thumbs-up using the
            // same hand throughout. It is drawn as a retained SwiftUI shape
            // rather than cropped from an unrelated pose sheet.
            return nil
        }
    }
}
