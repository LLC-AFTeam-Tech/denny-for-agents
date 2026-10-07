import Foundation

public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// For buttons: "Check with Codex".
    public var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

public enum HookEventName: String, Codable, Sendable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case permissionRequest = "PermissionRequest"
    case notification = "Notification"
    case stop = "Stop"
    case interrupt = "Interrupt"
    case other = "Other"
}

/// The subset of a Claude Code / Codex hook payload Denny cares about.
/// Long free-text fields are clipped so a socket message stays small.
public struct HookEvent: Codable, Equatable, Sendable {
    public static let maxTextLength = 2000

    public var agent: AgentKind
    public var name: HookEventName
    public var sessionId: String
    public var cwd: String?
    public var toolName: String?
    public var toolInput: [String: JSONValue]?
    public var prompt: String?
    public var message: String?
    public var notificationType: String?
    public var lastAssistantMessage: String?
    /// Set by the remote (SSH) hook so the notch can say where the agent runs.
    public var host: String?
    /// The remote user's home, so the Mac can tell where a sent file lands.
    public var home: String?
    /// Files saved by the hook right before a destructive command.
    public var snapshot: SafetySnapshot?
    /// Tokens of the task that just ended (Claude Code's Stop only).
    public var turnUsage: [UsageReport.Item]?
    /// Set when a night-shift job started this agent: nobody is watching.
    public var nightShift: String?
    /// The tool input was too long and is shortened here: whoever judges the
    /// risk from this copy can't see all of it.
    public var inputClipped: Bool?

    public init(
        agent: AgentKind,
        name: HookEventName,
        sessionId: String,
        cwd: String? = nil,
        toolName: String? = nil,
        toolInput: [String: JSONValue]? = nil,
        prompt: String? = nil,
        message: String? = nil,
        notificationType: String? = nil,
        lastAssistantMessage: String? = nil,
        host: String? = nil,
        home: String? = nil,
        snapshot: SafetySnapshot? = nil,
        turnUsage: [UsageReport.Item]? = nil,
        nightShift: String? = nil
    ) {
        self.agent = agent
        self.name = name
        self.sessionId = sessionId
        self.cwd = cwd
        self.toolName = toolName
        self.toolInput = toolInput
        self.prompt = prompt
        self.message = message
        self.notificationType = notificationType
        self.lastAssistantMessage = lastAssistantMessage
        self.host = host
        self.home = home
        self.snapshot = snapshot
        self.turnUsage = turnUsage
        self.nightShift = nightShift
    }

    private struct RawPayload: Decodable {
        var session_id: String?
        var hook_event_name: String?
        var cwd: String?
        var tool_name: String?
        var tool_input: JSONValue?
        var prompt: String?
        var message: String?
        var notification_type: String?
        var last_assistant_message: String?
    }

    public enum ParseError: Error, Equatable {
        case invalidJSON
        case missingSessionId
    }

    public static func parse(_ data: Data, agent: AgentKind) throws -> HookEvent {
        let raw: RawPayload
        do {
            raw = try JSONDecoder().decode(RawPayload.self, from: data)
        } catch {
            throw ParseError.invalidJSON
        }
        guard let sessionId = raw.session_id, !sessionId.isEmpty else {
            throw ParseError.missingSessionId
        }
        var toolInput: [String: JSONValue]?
        var inputClipped = false
        if case .object(let object)? = raw.tool_input {
            toolInput = object.mapValues(clipped)
            inputClipped = toolInput != object
        }
        var event = HookEvent(
            agent: agent,
            name: raw.hook_event_name.flatMap(HookEventName.init(rawValue:)) ?? .other,
            sessionId: sessionId,
            cwd: raw.cwd,
            toolName: raw.tool_name,
            toolInput: toolInput,
            prompt: raw.prompt.map(clip),
            message: raw.message.map(clip),
            notificationType: raw.notification_type,
            lastAssistantMessage: raw.last_assistant_message.map(clip)
        )
        if inputClipped { event.inputClipped = true }
        return event
    }

    /// The tool input exactly as the agent sent it. The event's own copy is
    /// shortened for showing; decisions must read this one.
    public static func fullToolInput(_ data: Data) -> [String: JSONValue]? {
        guard let raw = try? JSONDecoder().decode(RawPayload.self, from: data),
              case .object(let object)? = raw.tool_input else { return nil }
        return object
    }

    static func clip(_ text: String) -> String {
        text.count > maxTextLength ? String(text.prefix(maxTextLength)) + "…" : text
    }

    private static func clipped(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text): return .string(clip(text))
        case .array(let items): return .array(Array(items.prefix(20)).map(clipped))
        case .object(let object): return .object(object.mapValues(clipped))
        default: return value
        }
    }
}
