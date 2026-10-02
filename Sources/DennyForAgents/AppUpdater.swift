import AgentCore
import AppKit
import CryptoKit

/// Checks GitHub releases once a day and, on request, replaces the app with
/// the new build. No Sparkle: it needs a paid Apple signature to install.
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    static let latestURL = URL(string: "https://api.github.com/repos/\(Updates.repository)/releases/latest")!
    static let checkEvery: TimeInterval = 24 * 3600

    enum State: Equatable {
        case idle, checking, upToDate, installing
        case available(ReleaseInfo)
        case homebrew(ReleaseInfo)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Called once per new version, for a notification.
    var onNewVersion: ((String) -> Void)?
    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// A cask install is upgraded by brew; replacing it here would confuse brew.
    static var installedWithHomebrew: Bool {
        ["/opt/homebrew/Caskroom/denny-for-agents", "/usr/local/Caskroom/denny-for-agents"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    func start() {
        check(quietly: true)
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkEvery, repeats: true) { [weak self] _ in
            self?.check(quietly: true)
        }
    }

    /// Main thread only.
    func check(quietly: Bool = false) {
        switch state {
        case .checking, .installing: return
        default: break
        }
        if !quietly { state = .checking }
        var request = URLRequest(url: Self.latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Denny-for-Agents", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode
            let release = status == 200 ? data.flatMap(Updates.parseLatest) : nil
            DispatchQueue.main.async {
                self?.finishCheck(release, reached: status != nil, quietly: quietly)
            }
        }.resume()
    }

    private func finishCheck(_ release: ReleaseInfo?, reached: Bool, quietly: Bool) {
        guard let release, Updates.isNewer(release.version, than: Self.currentVersion) else {
            if !quietly { state = reached ? .upToDate : .failed(L.updateOffline) }
            return
        }
        state = Self.installedWithHomebrew ? .homebrew(release) : .available(release)
        let key = "announcedVersion"
        if UserDefaults.standard.string(forKey: key) != release.version {
            UserDefaults.standard.set(release.version, forKey: key)
            onNewVersion?(release.version)
        }
    }

    /// Main thread only. Downloads, checks the SHA-256 from the release notes,
    /// unpacks, then swaps the app once this process has quit.
    func install(_ release: ReleaseInfo) {
        let target = Bundle.main.bundleURL
        guard let expected = release.sha256 else { return fail(L.updateBadChecksum) }
        guard target.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            return fail(L.updateNoPermission)
        }
        state = .installing
        URLSession.shared.downloadTask(with: release.downloadURL) { [weak self] file, response, _ in
            // The downloaded file is deleted when this closure returns, so move it first.
            let result = Result(catching: { () throws -> URL in
                guard let file, (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
                return try Self.unpack(file, expectedSHA256: expected)
            })
            DispatchQueue.main.async {
                switch result {
                case .success(let app): self?.swap(to: app, replacing: target)
                case .failure(let error): self?.fail((error as? UpdateError)?.message ?? L.updateDownloadFailed)
                }
            }
        }.resume()
    }

    private func fail(_ reason: String) {
        state = .failed(L.updateFailed(reason))
    }

    private enum UpdateError: Error {
        case download, checksum

        var message: String {
            switch self {
            case .download: return L.updateDownloadFailed
            case .checksum: return L.updateBadChecksum
            }
        }
    }

    private static func unpack(_ file: URL, expectedSHA256: String) throws -> URL {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("denny-update-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appendingPathComponent("update.zip")
        try fm.moveItem(at: file, to: zip)
        let digest = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256 else { throw UpdateError.checksum }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0,
              let app = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
              Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
        else { throw UpdateError.download }
        return app
    }

    /// A tiny shell script waits for this process to exit, moves the old app
    /// aside, puts the new one in place (or restores the old one) and opens it.
    private func swap(to app: URL, replacing target: URL) {
        let script = """
        while kill -0 "$0" 2>/dev/null; do sleep 0.2; done
        backup="$2.previous-$$"
        if mv "$2" "$backup"; then
          if mv "$1" "$2"; then rm -rf "$backup"; else mv "$backup" "$2"; fi
        fi
        xattr -cr "$2" 2>/dev/null
        open "$2"
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, String(ProcessInfo.processInfo.processIdentifier), app.path, target.path]
        do {
            try task.run()
        } catch {
            return fail(L.updateDownloadFailed)
        }
        NSApp.terminate(nil)
    }
}
