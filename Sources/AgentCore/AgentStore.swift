import Foundation

public enum SessionStatus: String, Equatable, Sendable {
    case idle
    case working
    case waitingApproval
    case waitingInput
    case finished
}

public struct AgentSession: Equatable, Identifiable, Sendable {
    public static let maxSteps = 5

    public let id: String
    public let agent: AgentKind
    public let sessionId: String
    public var cwd: String?
    public var host: String?
    public var home: String?
    public var status: SessionStatus
    public var currentStep: String?
    public var recentSteps: [String]
    public var lastMessage: String?
    public var updatedAt: Date
    /// When the current turn began, for the timer in the closed notch.
    public var turnStartedAt: Date?
    public var stepKind: StepKind?
    /// For the relay note: what was asked and what the agent touched.
    public var lastPrompt: String?
    public var touchedFiles: [String] = []
    public var commands: [String] = []
    /// This turn's tool calls, for spotting an agent going in circles.
    public var history: [StepRecord] = []
    /// Stuck warnings already given this turn.
    public var stuckWarned: Set<String> = []
    /// Files edited and commands run in the current task, for its receipt.
    public var turnFiles: [String] = []
    public var turnCommands = 0
    public static let maxHistory = 80

    public static let maxTouched = 20
    public static let maxCommands = 10

    public var projectName: String {
        guard let cwd, !cwd.isEmpty else { return agent.displayName }
        return (cwd as NSString).lastPathComponent
    }
}

extension AgentSession {
    mutating func remember(toolName: String?, input: [String: JSONValue]) {
        switch StepDescriber.kind(toolName: toolName) {
        case .writing:
            if let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue ?? input["notebook_path"]?.stringValue
                ?? StepDescriber.patchedPath(input) {
                touchedFiles.removeAll { $0 == path }
                touchedFiles.append(path)
                if touchedFiles.count > Self.maxTouched { touchedFiles.removeFirst(touchedFiles.count - Self.maxTouched) }
            }
        case .running:
            if let command = StepDescriber.command(from: input) {
                let short = StepDescriber.shortCommand(command)
                commands.removeAll { $0 == short }
                commands.append(short)
                if commands.count > Self.maxCommands { commands.removeFirst(commands.count - Self.maxCommands) }
            }
        default:
            break
        }
    }
}

public struct PendingApproval: Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionKey: String
    public let agent: AgentKind
    public let projectName: String
    public let host: String?
    public let summary: String
    public let detail: String?
    public let receivedAt: Date
    /// Denny's read of how risky this is.
    public let risk: RiskAssessment
}

/// What Denny should do in response to a state change.
public enum AgentStoreEffect: Equatable, Sendable {
    case celebrate(sessionKey: String, duration: TimeInterval?)
    /// The agent switched to writing code or planning.
    case startedStep(sessionKey: String, kind: StepKind)
    case turnStarted(sessionKey: String)
    /// The agent seems to be going in circles.
    case looksStuck(sessionKey: String, reason: StuckReason)
    case needsAttention(approvalId: String)
    /// The hook saved the files right before a destructive command.
    case snapshotTaken(sessionKey: String, snapshot: SafetySnapshot)
    /// A task ended: what it changed and cost.
    case receipt(TaskReceipt)
}

public enum AgentMood: Equatable, Sendable {
    case idle
    case working
    case needsYou
}

/// Pure model of every live agent session. No I/O, no timers: the app feeds
/// it events and a clock, and renders what it holds.
public struct AgentStore: Equatable, Sendable {
    public static let finishedLifetime: TimeInterval = 10 * 60
    public static let staleLifetime: TimeInterval = 2 * 60 * 60

    public private(set) var sessions: [String: AgentSession] = [:]
    public private(set) var approvals: [PendingApproval] = []
    public var language: UILanguage

    public init(language: UILanguage = .current) {
        self.language = language
    }

    public static func key(agent: AgentKind, sessionId: String) -> String {
        "\(agent.rawValue):\(sessionId)"
    }

    /// Sessions that need you first, then the most recently active.
    public var orderedSessions: [AgentSession] {
        sessions.values.sorted { lhs, rhs in
            let lhsUrgent = lhs.status == .waitingApproval || lhs.status == .waitingInput
            let rhsUrgent = rhs.status == .waitingApproval || rhs.status == .waitingInput
            if lhsUrgent != rhsUrgent { return lhsUrgent }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public var mood: AgentMood {
        if !approvals.isEmpty || sessions.values.contains(where: { $0.status == .waitingInput }) {
            return .needsYou
        }
        if sessions.values.contains(where: { $0.status == .working }) {
            return .working
        }
        return .idle
    }

    @discardableResult
    public mutating func apply(_ event: HookEvent, requestId: String? = nil, now: Date = Date()) -> [AgentStoreEffect] {
        let key = Self.key(agent: event.agent, sessionId: event.sessionId)
        let texts = Texts(language: language)

        // Placeholders (usage reports, the server worker) aren't sessions.
        if event.name == .other { return [] }
        if event.name == .sessionEnd {
            sessions[key] = nil
            approvals.removeAll { $0.sessionKey == key }
            return []
        }

        var session = sessions[key] ?? AgentSession(
            id: key,
            agent: event.agent,
            sessionId: event.sessionId,
            cwd: event.cwd,
            host: event.host,
            home: event.home,
            status: .idle,
            currentStep: nil,
            recentSteps: [],
            lastMessage: nil,
            updatedAt: now,
            turnStartedAt: nil,
            stepKind: nil,
            lastPrompt: nil
        )
        if let cwd = event.cwd { session.cwd = cwd }
        if let host = event.host { session.host = host }
        if let home = event.home { session.home = home }
        session.updatedAt = now
        var effects: [AgentStoreEffect] = []

        switch event.name {
        case .sessionStart:
            break
        case .userPromptSubmit:
            session.status = .working
            session.currentStep = texts.thinking
            session.recentSteps = []
            session.lastMessage = nil
            session.turnStartedAt = now
            session.stepKind = nil
            if let prompt = event.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                session.lastPrompt = prompt
            }
            session.history = []
            session.stuckWarned = []
            session.turnFiles = []
            session.turnCommands = 0
            effects.append(.turnStarted(sessionKey: key))
        case .preToolUse:
            let step = StepDescriber.describe(toolName: event.toolName, toolInput: event.toolInput, language: language)
            if session.turnStartedAt == nil { session.turnStartedAt = now }
            let kind = StepDescriber.kind(toolName: event.toolName)
            if kind != session.stepKind, kind == .writing || kind == .planning {
                effects.append(.startedStep(sessionKey: key, kind: kind))
            }
            session.stepKind = kind
            if let snapshot = event.snapshot { effects.append(.snapshotTaken(sessionKey: key, snapshot: snapshot)) }
            session.remember(toolName: event.toolName, input: event.toolInput ?? [:])
            switch kind {
            case .writing:
                let input = event.toolInput ?? [:]
                if let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue ?? input["notebook_path"]?.stringValue
                    ?? StepDescriber.patchedPath(input), !session.turnFiles.contains(path) {
                    session.turnFiles.append(path)
                }
            case .running:
                session.turnCommands += 1
            default:
                break
            }
            session.history.append(StepRecord(at: now, kind: kind, target: StuckDetector.target(toolName: event.toolName,
                                                                                               input: event.toolInput ?? [:])))
            if session.history.count > AgentSession.maxHistory {
                session.history.removeFirst(session.history.count - AgentSession.maxHistory)
            }
            if let reason = StuckDetector.check(session.history, turnStartedAt: session.turnStartedAt, now: now),
               !session.stuckWarned.contains(reason.id) {
                session.stuckWarned.insert(reason.id)
                effects.append(.looksStuck(sessionKey: key, reason: reason))
            }
            session.status = .working
            session.currentStep = step
            session.recentSteps.append(step)
            if session.recentSteps.count > AgentSession.maxSteps {
                session.recentSteps.removeFirst(session.recentSteps.count - AgentSession.maxSteps)
            }
        case .postToolUse:
            if session.status != .waitingApproval { session.status = .working }
        case .permissionRequest:
            guard let requestId else { break }
            let summary = StepDescriber.describe(toolName: event.toolName, toolInput: event.toolInput, language: language)
            session.status = .waitingApproval
            session.currentStep = summary
            approvals.append(PendingApproval(
                id: requestId,
                sessionKey: key,
                agent: event.agent,
                projectName: session.projectName,
                host: session.host,
                summary: summary,
                detail: Self.approvalDetail(event),
                receivedAt: now,
                risk: RiskRadar.assess(toolName: event.toolName, toolInput: event.toolInput)
            ))
            effects.append(.needsAttention(approvalId: requestId))
        case .notification:
            // Permission prompts arrive as PermissionRequest; only the
            // "agent is idle, your turn" notice matters here.
            if event.notificationType == "idle_prompt" {
                session.status = .waitingInput
                session.currentStep = texts.waitingForYou
            }
        case .stop, .interrupt:
            let duration = session.turnStartedAt.map { now.timeIntervalSince($0) }
            approvals.removeAll { $0.sessionKey == key }
            session.status = .finished
            session.currentStep = texts.done
            session.turnStartedAt = nil
            session.stepKind = nil
            session.lastMessage = event.lastAssistantMessage
            if event.name == .stop {
                effects.append(.celebrate(sessionKey: key, duration: duration))
                let usage = event.turnUsage ?? []
                if !session.turnFiles.isEmpty || session.turnCommands > 0 || !usage.isEmpty {
                    effects.append(.receipt(TaskReceipt(
                        sessionKey: key, agent: session.agent, projectName: session.projectName, cwd: session.cwd,
                        host: session.host, duration: duration, finishedAt: now, files: session.turnFiles,
                        commands: session.turnCommands, usage: usage, prompt: session.lastPrompt)))
                }
            }
        case .sessionEnd, .other:
            break
        }

        sessions[key] = session
        return effects
    }

    /// The user answered in the notch (or the hook went away). Returns the
    /// approval so the caller can reply to the waiting hook.
    @discardableResult
    public mutating func resolveApproval(id: String, now: Date = Date()) -> PendingApproval? {
        guard let index = approvals.firstIndex(where: { $0.id == id }) else { return nil }
        let approval = approvals.remove(at: index)
        if var session = sessions[approval.sessionKey],
           !approvals.contains(where: { $0.sessionKey == approval.sessionKey }) {
            session.status = .working
            session.updatedAt = now
            sessions[approval.sessionKey] = session
        }
        return approval
    }

    public mutating func prune(now: Date = Date()) {
        sessions = sessions.filter { _, session in
            let age = now.timeIntervalSince(session.updatedAt)
            if session.status == .finished { return age < Self.finishedLifetime }
            if session.status == .waitingApproval { return true }
            return age < Self.staleLifetime
        }
        approvals.removeAll { sessions[$0.sessionKey] == nil }
    }

    static func approvalDetail(_ event: HookEvent) -> String? {
        let input = event.toolInput ?? [:]
        if let command = StepDescriber.command(from: input) {
            return HookEvent.clip(command)
        }
        if let description = input["description"]?.stringValue {
            return description
        }
        if let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue {
            return path
        }
        return nil
    }
}
