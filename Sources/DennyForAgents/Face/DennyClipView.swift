import AgentCore
import AppKit
import AVFoundation
import SwiftUI

/// What Denny is busy with in the activity peek.
enum DennyActivity: String, Equatable {
    case notes, tasks
}

/// A short reaction to an event, played over the looping notch clips.
enum DennyReaction: String {
    case joy, scared, idea, think

    var file: String { "react-\(rawValue).mp4" }
    /// The clips run 3 s.
    static let duration: TimeInterval = 3.1
}

/// One reaction being shown; the id restarts the clip for a repeat.
struct DennyReactionPlay: Equatable {
    let reaction: DennyReaction
    let id = UUID()
}

/// Finds DennyClips in the resource bundle: next to the binary after
/// `swift build`, in Contents/Resources in the packaged app.
enum DennyClips {
    static let directory: URL? = {
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .deletingLastPathComponent()
        let searchDirectories = [executableDirectory, Bundle.main.resourceURL].compactMap { $0 }
        for directory in searchDirectories {
            let bundles = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ))?.filter { $0.pathExtension == "bundle" } ?? []
            for bundle in bundles {
                for clips in [bundle.appendingPathComponent("DennyClips"),
                              bundle.appendingPathComponent("Contents/Resources/DennyClips")]
                where FileManager.default.fileExists(atPath: clips.appendingPathComponent("notch-idle.mp4").path) {
                    return clips
                }
            }
        }
        return Bundle.module.url(forResource: "DennyClips", withExtension: nil)
    }()
}

/// A short clip from DennyClips, played once from the start.
struct DennyClipView: NSViewRepresentable {
    let file: String

    static func finishFile(_ agent: AgentKind) -> String { "finish-\(agent.rawValue).mp4" }
    static let notchLoopFiles = ["notch-idle.mp4", "notch-crawl.mp4", "notch-hide.mp4"]

    static func workFile(_ activity: DennyActivity) -> String {
        activity == .notes ? "work-laptop.mp4" : "work-notebook.mp4"
    }

    static func url(_ file: String) -> URL? {
        guard let url = DennyClips.directory?.appendingPathComponent(file),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        if let url = Self.url(file) { view.play(url) }
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {}

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
        view.player.pause()
    }

    final class PlayerView: NSView {
        let player = AVPlayer()
        private let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            player.isMuted = true
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }

        func play(_ url: URL) {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.play()
        }
    }
}

/// Denny's clips back to back in random order. Each clip starts and ends
/// in the same pose, so the joins don't jump.
struct DennyLoopView: NSViewRepresentable {
    var files: [String] = DennyClipView.notchLoopFiles

    func makeNSView(context: Context) -> DennyClipView.PlayerView {
        let view = DennyClipView.PlayerView()
        let urls = files.compactMap(DennyClipView.url)
        context.coordinator.start(view, urls: urls)
        return view
    }

    func updateNSView(_ view: DennyClipView.PlayerView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ view: DennyClipView.PlayerView, coordinator: Coordinator) {
        coordinator.stop()
        view.player.pause()
    }

    final class Coordinator {
        private var observer: NSObjectProtocol?
        private var urls: [URL] = []
        private var current: URL?

        func start(_ view: DennyClipView.PlayerView, urls: [URL]) {
            self.urls = urls
            observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
            ) { [weak self, weak view] note in
                guard let self, let view, (note.object as? AVPlayerItem) === view.player.currentItem else { return }
                self.playNext(view)
            }
            playNext(view)
        }

        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        private func playNext(_ view: DennyClipView.PlayerView) {
            let choices = urls.count > 1 ? urls.filter { $0 != current } : urls
            guard let next = choices.randomElement() else { return }
            current = next
            view.play(next)
        }
    }
}

/// Denny in the notch: the looping clips, or a reaction for a moment.
struct DennyLiveView: View {
    let reaction: DennyReactionPlay?

    var body: some View {
        if let reaction {
            DennyClipView(file: reaction.reaction.file).id(reaction.id)
        } else {
            DennyLoopView()
        }
    }
}
