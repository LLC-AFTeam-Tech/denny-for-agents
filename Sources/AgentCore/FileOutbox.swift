import Foundation

/// Files dropped on the notch while the agent runs on an SSH server. They
/// wait here until that server's hook asks (when you send the agent your
/// next message) and are then written to ~/denny-inbox/<dir>/<name> there.
public struct FileOutbox: Sendable {
    public static let maxBytes = 20 * 1024 * 1024
    public static let lifetime: TimeInterval = 60 * 60

    public struct Item: Equatable, Sendable {
        public let dir: String
        public let name: String
        public let data: Data
        public let createdAt: Date

        public init(dir: String, name: String, data: Data, createdAt: Date) {
            self.dir = dir
            self.name = name
            self.data = data
            self.createdAt = createdAt
        }
    }

    private var pending: [String: [Item]] = [:]

    public init() {}

    public static func safeName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty || base == "." || base == ".." ? "file" : base
    }

    public static func folder(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    public static func remotePath(home: String, dir: String, name: String) -> String {
        "\(home)/denny-inbox/\(dir)/\(safeName(name))"
    }

    public mutating func add(_ items: [Item], host: String) {
        pending[host, default: []].append(contentsOf: items)
    }

    public mutating func take(host: String, now: Date = Date()) -> [Item] {
        let items = (pending.removeValue(forKey: host) ?? []).filter { now.timeIntervalSince($0.createdAt) < Self.lifetime }
        return items
    }

    public func count(host: String) -> Int {
        pending[host]?.count ?? 0
    }
}

/// app -> hook, answer to a request with `wantsFiles`.
public struct FileDelivery: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public var dir: String
        public var name: String
        /// Base64.
        public var data: String
    }

    public var id: String
    public var files: [File]

    public init(id: String, items: [FileOutbox.Item]) {
        self.id = id
        self.files = items.map { File(dir: $0.dir, name: FileOutbox.safeName($0.name), data: $0.data.base64EncodedString()) }
    }
}
