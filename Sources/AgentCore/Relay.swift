import Foundation

/// "Relay": when one agent hits its plan limit, hand the task to the other
/// one with a note of what was asked and what was already done.
public struct RelayOffer: Equatable, Sendable {
    public let sessionKey: String
    public let from: AgentKind
    public let to: AgentKind
    /// When the exhausted limit renews, if known.
    public let resetsAt: Double?

    /// Each offer is made once per session and limit period.
    public var id: String { "\(sessionKey)|\(resetsAt.map { String(Int($0)) } ?? "?")" }
}

public enum Relay {
    public static let exhaustedAt: Double = 98
    public static let recentWork: TimeInterval = 3 * 3600

    public static func other(_ agent: AgentKind) -> AgentKind { agent == .claude ? .codex : .claude }

    /// An agent at its limit with recent work, and the other one with room left.
    public static func offer(summary: UsageSummary, sessions: [AgentSession], available: Set<AgentKind>,
                             now: Date = Date()) -> RelayOffer? {
        for from in AgentKind.allCases {
            let to = other(from)
            guard available.contains(to) else { continue }
            let windows = (summary.limits[from]?.windows ?? []).filter { !$0.isStale }
            guard let exhausted = windows.filter({ $0.percent >= exhaustedAt }).max(by: { ($0.resetsAt ?? 0) < ($1.resetsAt ?? 0) }) else { continue }
            let targetFull = (summary.limits[to]?.windows ?? []).contains { !$0.isStale && $0.percent >= 95 }
            guard !targetFull else { continue }
            let recent = sessions
                .filter { $0.agent == from && $0.lastPrompt != nil && now.timeIntervalSince($0.updatedAt) < recentWork }
                .max { $0.updatedAt < $1.updatedAt }
            guard let session = recent else { continue }
            return RelayOffer(sessionKey: session.id, from: from, to: to, resetsAt: exhausted.resetsAt)
        }
        return nil
    }

    /// The text to paste into the other agent.
    public static func note(for session: AgentSession, to: AgentKind, becauseOfLimit: Bool, language: UILanguage) -> String {
        func t(_ key: String, _ args: CVarArg...) -> String { Translations.format(key, language, args) }
        var lines: [String] = []
        let why = t(becauseOfLimit ? "relay.note.reasonLimit" : "relay.note.reasonManual")
        lines.append(t("relay.note.intro", session.agent.displayName, why))
        if let cwd = session.cwd { lines.append(t("relay.note.folder", cwd)) }
        if let host = session.host { lines.append(t("relay.note.server", host)) }
        if let prompt = session.lastPrompt {
            lines.append("")
            lines.append(t("relay.note.task"))
            lines.append(prompt)
        }
        if !session.touchedFiles.isEmpty || !session.commands.isEmpty {
            lines.append("")
            lines.append(t("relay.note.done"))
            if !session.touchedFiles.isEmpty {
                let files = session.touchedFiles.map { relative($0, to: session.cwd) }
                lines.append("- " + t("relay.note.edited", files.joined(separator: ", ")))
            }
            if !session.commands.isEmpty {
                lines.append("- " + t("relay.note.ran", session.commands.joined(separator: "; ")))
            }
        }
        if let last = session.lastMessage, !last.isEmpty {
            lines.append("")
            lines.append(t("relay.note.last", session.agent.displayName))
            lines.append(last.count > 600 ? String(last.prefix(600)) + "…" : last)
        }
        lines.append("")
        lines.append(t("relay.note.next"))
        return lines.joined(separator: "\n")
    }

    static func relative(_ path: String, to cwd: String?) -> String {
        guard let cwd, path.hasPrefix(cwd + "/") else { return path }
        return String(path.dropFirst(cwd.count + 1))
    }
}
