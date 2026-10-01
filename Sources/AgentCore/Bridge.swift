import Foundation

public enum ApprovalDecision: String, Codable, Sendable {
    case allow
    case deny
    /// Leave the decision to the agent's own prompt in the terminal.
    case ask
}

/// hook -> app, one JSON line.
public struct BridgeRequest: Codable, Equatable, Sendable {
    public var version: Int
    public var id: String
    public var event: HookEvent
    public var wantsDecision: Bool

    public init(id: String, event: HookEvent, wantsDecision: Bool) {
        self.version = 1
        self.id = id
        self.event = event
        self.wantsDecision = wantsDecision
    }
}

/// app -> hook, one JSON line, only for requests that want a decision.
public struct BridgeResponse: Codable, Equatable, Sendable {
    public var id: String
    public var decision: ApprovalDecision

    public init(id: String, decision: ApprovalDecision) {
        self.id = id
        self.decision = decision
    }
}

public enum BridgeCodec {
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }
}

public enum BridgePaths {
    public static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".denny-for-agents", isDirectory: true)
    }

    public static func socket(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        directory(home: home).appendingPathComponent("agents.sock")
    }

    public static func hookBinary(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        directory(home: home).appendingPathComponent("bin/denny-hook")
    }
}
