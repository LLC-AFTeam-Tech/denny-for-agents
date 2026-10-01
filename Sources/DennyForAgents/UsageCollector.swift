import AgentCore
import Foundation

/// Runs the bundled `denny-hook.py --report` on this Mac once a minute. The
/// first run reads a month of logs and can take a while; later runs only
/// read what was appended.
final class UsageCollector {
    static let interval: TimeInterval = 60

    var onReport: ((UsageReport) -> Void)?

    private let queue = DispatchQueue(label: "denny.usage")
    private var timer: Timer?
    private var running = false

    static var script: URL? {
        Bundle.main.url(forResource: "denny-hook", withExtension: "py")
    }

    static var python: URL? {
        ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Main thread only.
    func refresh() {
        guard !running, let script = Self.script, let python = Self.python else { return }
        running = true
        queue.async { [weak self] in
            let report = Self.run(python: python, script: script)
            DispatchQueue.main.async {
                self?.running = false
                if let report { self?.onReport?(report) }
            }
        }
    }

    /// Spends one Codex reset credit through this Mac's Codex. Calls back on
    /// the main thread with the outcome: reset, nothingToReset, noCredit,
    /// alreadyRedeemed or failed.
    func resetCodex(completion: @escaping (String) -> Void) {
        guard let script = Self.script, let python = Self.python else { return completion("failed") }
        queue.async {
            let data = Self.output(python: python, arguments: [script.path, "--codex-reset"])
            let outcome = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["outcome"] as? String
            DispatchQueue.main.async { completion(outcome ?? "failed") }
        }
    }

    private static func run(python: URL, script: URL) -> UsageReport? {
        guard let data = output(python: python, arguments: [script.path, "--report"]) else { return nil }
        return try? JSONDecoder().decode(UsageReport.self, from: data)
    }

    private static func output(python: URL, arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = python
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }
}
