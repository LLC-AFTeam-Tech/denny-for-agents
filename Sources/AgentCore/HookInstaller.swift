import Foundation

/// Adds Denny's hook entries to Claude Code's `~/.claude/settings.json`
/// and Codex's `~/.codex/hooks.json`, leaving everything else untouched.
/// Our entries are recognised by the hook binary name, so install is
/// idempotent and uninstall removes only what we added.
public enum HookInstaller {
    public static let marker = "denny-hook"

    /// Hook timeout for approvals: the hook gives up earlier on its own
    /// (see `approvalWaitSeconds`) and hands the decision back to the terminal.
    public static let approvalTimeoutSeconds = 600
    public static let approvalWaitSeconds = 300
    public static let eventTimeoutSeconds = 5

    public static func events(for agent: AgentKind) -> [HookEventName] {
        switch agent {
        case .claude:
            return [.sessionStart, .sessionEnd, .userPromptSubmit, .preToolUse, .postToolUse, .permissionRequest, .notification, .stop]
        case .codex:
            return [.sessionStart, .sessionEnd, .userPromptSubmit, .preToolUse, .postToolUse, .permissionRequest, .stop]
        }
    }

    public static func configURL(for agent: AgentKind, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        switch agent {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex: return home.appendingPathComponent(".codex/hooks.json")
        }
    }

    public static func command(hookPath: String, agent: AgentKind) -> String {
        "'\(hookPath.replacingOccurrences(of: "'", with: "'\\''"))' \(agent.rawValue)"
    }

    // MARK: - Pure merge / removal

    /// Claude keeps hooks under a top-level "hooks" key; Codex's hooks.json
    /// is the hooks table itself.
    public static func merged(config: [String: Any], agent: AgentKind, hookPath: String) -> [String: Any] {
        var table = hooksTable(in: config, agent: agent)
        table = removingOurs(from: table)
        for event in events(for: agent) {
            var entries = table[event.rawValue] as? [Any] ?? []
            let timeout = event == .permissionRequest ? approvalTimeoutSeconds : eventTimeoutSeconds
            entries.append([
                "hooks": [[
                    "type": "command",
                    "command": command(hookPath: hookPath, agent: agent),
                    "timeout": timeout
                ]]
            ])
            table[event.rawValue] = entries
        }
        return withHooksTable(table, in: config, agent: agent)
    }

    public static func removed(config: [String: Any], agent: AgentKind) -> [String: Any] {
        let table = removingOurs(from: hooksTable(in: config, agent: agent))
        return withHooksTable(table, in: config, agent: agent)
    }

    public static func isInstalled(config: [String: Any], agent: AgentKind) -> Bool {
        let table = hooksTable(in: config, agent: agent)
        return table.values.contains { value in
            (value as? [Any] ?? []).contains(where: isOurEntry)
        }
    }

    private static func hooksTable(in config: [String: Any], agent: AgentKind) -> [String: Any] {
        switch agent {
        case .claude: return config["hooks"] as? [String: Any] ?? [:]
        case .codex: return config
        }
    }

    private static func withHooksTable(_ table: [String: Any], in config: [String: Any], agent: AgentKind) -> [String: Any] {
        switch agent {
        case .claude:
            var next = config
            next["hooks"] = table.isEmpty ? nil : table
            return next
        case .codex:
            return table
        }
    }

    private static func removingOurs(from table: [String: Any]) -> [String: Any] {
        var next: [String: Any] = [:]
        for (event, value) in table {
            guard let entries = value as? [Any] else {
                next[event] = value
                continue
            }
            let kept = entries.filter { !isOurEntry($0) }
            if !kept.isEmpty { next[event] = kept }
        }
        return next
    }

    private static func isOurEntry(_ entry: Any) -> Bool {
        guard let object = entry as? [String: Any], let hooks = object["hooks"] as? [Any] else { return false }
        return hooks.contains { hook in
            ((hook as? [String: Any])?["command"] as? String)?.contains(marker) == true
        }
    }

    // MARK: - Files

    public enum InstallError: Error, Equatable {
        case unreadableConfig(String)
    }

    public static func readConfig(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Never overwrite a file we cannot parse -- it may hold the
            // user's settings in a form we don't understand.
            throw InstallError.unreadableConfig(url.path)
        }
        return object
    }

    /// Writes `config`, first copying the previous file next to it.
    public static func writeConfig(_ config: [String: Any], to url: URL, now: Date = Date()) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let stamp = Int(now.timeIntervalSince1970)
            let backup = url.appendingPathExtension("denny-backup-\(stamp)")
            if !fm.fileExists(atPath: backup.path) {
                try fm.copyItem(at: url, to: backup)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    public static func install(agent: AgentKind, hookPath: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let url = configURL(for: agent, home: home)
        let config = try readConfig(at: url)
        try writeConfig(merged(config: config, agent: agent, hookPath: hookPath), to: url)
    }

    public static func uninstall(agent: AgentKind, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let url = configURL(for: agent, home: home)
        let config = try readConfig(at: url)
        guard isInstalled(config: config, agent: agent) else { return }
        try writeConfig(removed(config: config, agent: agent), to: url)
    }

    public static func isInstalled(agent: AgentKind, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let config = try? readConfig(at: configURL(for: agent, home: home)) else { return false }
        return isInstalled(config: config, agent: agent)
    }
}
