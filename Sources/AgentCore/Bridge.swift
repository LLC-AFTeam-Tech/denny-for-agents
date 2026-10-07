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
    /// Required on the TCP (remote) listener, ignored on the local socket.
    public var token: String?
    /// Usage and plan limits from a remote server, sent in the background.
    public var report: UsageReport?
    /// The remote hook waits for a FileDelivery line in reply.
    public var wantsFiles: Bool?
    /// The server worker waits for a JobBatch line in reply.
    public var wantsJobs: Bool?
    public var jobResults: [RemoteJobResult]?
    /// Ids of jobs the worker has stored since the last exchange. The Mac keeps
    /// a job until its id comes back here; nil from an older hook (no acks).
    public var jobsReceived: [String]?

    public init(id: String, event: HookEvent, wantsDecision: Bool, token: String? = nil, report: UsageReport? = nil) {
        self.version = 1
        self.id = id
        self.event = event
        self.wantsDecision = wantsDecision
        self.token = token
        self.report = report
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

    public static func remoteToken(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        directory(home: home).appendingPathComponent("remote-token")
    }
}

/// Remote mode: hooks on an SSH server reach Denny through a forwarded
/// loopback port. Only 127.0.0.1 is ever bound, and every request must
/// carry the token, so other local processes can't post fake cards.
public enum RemoteBridge {
    public static let defaultPort: UInt16 = 47321

    public static func loadOrCreateToken(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let url = BridgePaths.remoteToken(home: home)
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count >= 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandom.fill(&bytes) else { return nil }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard fm.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else { return nil }
        return token
    }

    public static func tokensMatch(_ provided: String?, _ expected: String) -> Bool {
        guard let provided else { return false }
        let a = Array(provided.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    public static func installCommand(port: UInt16, token: String) -> String {
        "python3 ~/.denny-for-agents/denny-hook.py --install --port \(port) --token \(token)"
    }
}

enum SecRandom {
    static func fill(_ bytes: inout [UInt8]) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: "/dev/urandom") else { return false }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: bytes.count)
        guard data.count == bytes.count else { return false }
        bytes = Array(data)
        return true
    }
}
