import Foundation

/// A task queued for later: when the plan limit renews, or at a set time.
public struct NightJob: Codable, Equatable, Sendable, Identifiable {
    public enum Trigger: Codable, Equatable, Sendable {
        /// When the limit that was full renews (its reset time, if known).
        case limitRenews(resetsAt: Double?)
        case at(Date)
    }

    public enum State: Codable, Equatable, Sendable {
        case waiting
        case running(since: Date)
        case done(at: Date)
        case failed(at: Date, reason: String)
    }

    public var id: String
    public var agent: AgentKind
    public var folder: String
    public var prompt: String
    public var trigger: Trigger
    public var createdAt: Date
    public var state: State

    public init(agent: AgentKind, folder: String, prompt: String, trigger: Trigger, createdAt: Date = Date()) {
        self.id = UUID().uuidString
        self.agent = agent
        self.folder = folder
        self.prompt = prompt
        self.trigger = trigger
        self.createdAt = createdAt
        self.state = .waiting
    }
}

/// "Night shift": queued tasks start on their own, unattended, under the
/// careful policy — edits and safe commands go ahead, anything the guard
/// calls dangerous is refused. The safety net still snapshots.
public enum NightShift {
    /// Set for the agent process, so its hooks know nobody is watching.
    public static let environmentKey = "DENNY_NIGHT_SHIFT"
    public static let timeout: TimeInterval = 3 * 3600

    public static func file(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        BridgePaths.directory(home: home).appendingPathComponent("night-shift.json")
    }

    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [NightJob] {
        guard let data = try? Data(contentsOf: file(home: home)) else { return [] }
        return (try? JSONDecoder().decode([NightJob].self, from: data)) ?? []
    }

    public static func save(_ jobs: [NightJob], home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        try? FileManager.default.createDirectory(at: BridgePaths.directory(home: home), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: file(home: home), options: .atomic)
    }

    /// The trigger for "when the limit renews": the reset of the fullest
    /// window now, so a job queued at 100% waits for it.
    public static func renewTrigger(_ limits: UsageReport.Limits?) -> NightJob.Trigger {
        let full = (limits?.windows ?? []).filter { !$0.isStale && $0.percent >= 90 }
        return .limitRenews(resetsAt: full.compactMap(\.resetsAt).max())
    }

    /// Whether a waiting job may start now.
    public static func isDue(_ job: NightJob, limits: UsageReport.Limits?, now: Date = Date()) -> Bool {
        guard job.state == .waiting else { return false }
        switch job.trigger {
        case .at(let date):
            return now >= date
        case .limitRenews(let resetsAt):
            if let resetsAt { return now.timeIntervalSince1970 >= resetsAt + 60 }
            return !(limits?.windows ?? []).contains { !$0.isStale && $0.percent >= 95 }
        }
    }

    /// The careful policy: dangerous and critical requests are refused.
    public static func decision(for risk: RiskAssessment) -> ApprovalDecision {
        risk.level >= .danger ? .deny : .allow
    }

    /// Claude Code's PreToolUse answer, given before any permission prompt.
    public static func preToolUseOutput(_ decision: ApprovalDecision, risk: RiskAssessment) -> String? {
        guard decision != .ask else { return nil }
        var output: [String: Any] = [
            "hookEventName": HookEventName.preToolUse.rawValue,
            "permissionDecision": decision == .allow ? "allow" : "deny"
        ]
        if decision == .deny {
            output["permissionDecisionReason"] = "Denny for Agents night shift: this looks dangerous (\(risk.reasons.first?.key ?? "risky")) and nobody is here to approve it. Find a safer way or leave it for the morning."
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": output], options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The headless command line: Claude accepts edits (commands go through
    /// the hook's policy); Codex works in its workspace sandbox, offline.
    public static func arguments(_ job: NightJob) -> [String] {
        switch job.agent {
        case .claude: return ["-p", job.prompt, "--permission-mode", "acceptEdits"]
        case .codex: return ["exec", "--sandbox", "workspace-write", "--skip-git-repo-check", job.prompt]
        }
    }
}
