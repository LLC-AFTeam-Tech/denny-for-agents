import AgentCore
import Foundation

/// Copies `denny-hook` out of the app to ~/.denny-for-agents/bin so the
/// agents' settings point at a path that survives moving or updating the app.
enum HookSetup {
    enum SetupError: LocalizedError {
        case hookBinaryMissing

        var errorDescription: String? {
            "denny-hook was not found next to the app binary."
        }
    }

    static var bundledHook: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("denny-hook")
    }

    @discardableResult
    static func installBinary() throws -> String {
        let fm = FileManager.default
        guard let source = bundledHook, fm.fileExists(atPath: source.path) else {
            throw SetupError.hookBinaryMissing
        }
        let target = BridgePaths.hookBinary()
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.appendingPathExtension("new")
        try? fm.removeItem(at: temporary)
        try fm.copyItem(at: source, to: temporary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: target)
        }
        return target.path
    }

    static func setEnabled(_ enabled: Bool, agent: AgentKind) throws {
        if enabled {
            let path = try installBinary()
            try HookInstaller.install(agent: agent, hookPath: path)
        } else {
            try HookInstaller.uninstall(agent: agent)
        }
    }

    static var anyInstalled: Bool {
        AgentKind.allCases.contains { HookInstaller.isInstalled(agent: $0) }
    }

    /// After an app update the copied hook may be outdated.
    static func refreshBinaryIfNeeded() {
        if anyInstalled { _ = try? installBinary() }
    }
}
