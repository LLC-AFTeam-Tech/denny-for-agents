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
    public var status: SessionStatus
    public var currentStep: String?
    public var recentSteps: [String]
    public var lastMessage: String?
    public var updatedAt: Date

    public var projectName: String {
        guard let cwd, !cwd.isEmpty else { return agent.displayName }
        return (cwd as NSString).lastPathComponent
    }
}

public struct PendingApproval: Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionKey: String
    public let agent: AgentKind
    public let projectName: String
    public let summary: String
    public let detail: String?
    public let receivedAt: Date
}

/// What Denny should do in response to a state change.
public enum AgentStoreEffect: Equatable, Sendable {
    case celebrate(sessionKey: String)
    case needsAttention(approvalId: String)
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
            status: .idle,
            currentStep: nil,
            recentSteps: [],
            lastMessage: nil,
            updatedAt: now
        )
        if let cwd = event.cwd { session.cwd = cwd }
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
        case .preToolUse:
            let step = StepDescriber.describe(toolName: event.toolName, toolInput: event.toolInput, language: language)
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
                summary: summary,
                detail: Self.approvalDetail(event),
                receivedAt: now
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
            approvals.removeAll { $0.sessionKey == key }
            session.status = .finished
            session.currentStep = texts.done
            session.lastMessage = event.lastAssistantMessage
            if event.name == .stop { effects.append(.celebrate(sessionKey: key)) }
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
