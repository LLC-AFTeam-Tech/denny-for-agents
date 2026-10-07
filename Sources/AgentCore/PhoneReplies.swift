import Foundation

/// Replying to "✅ done" in Telegram tells the agent what to do next. While the
/// user is away, the Stop hook of a task waits a few minutes for that reply and
/// the agent goes on in the same terminal; later on, the reply resumes the
/// session in the background, under the night shift's careful policy.
public enum PhoneReplies {
    public static let maxLength = 4000
    /// How long the Mac keeps a Stop hook waiting: a little under the hook's own wait.
    public static let holdSeconds: TimeInterval = TimeInterval(HookInstaller.replyWaitSeconds - 10)

    /// A finished task a reply can go on with.
    public struct Task: Codable, Equatable, Sendable {
        public var agent: AgentKind
        public var sessionId: String
        public var folder: String
        /// The server it ran on; nil for this Mac.
        public var host: String?

        public init(agent: AgentKind, sessionId: String, folder: String, host: String? = nil) {
            self.agent = agent
            self.sessionId = sessionId
            self.folder = folder
            self.host = host
        }
    }

    /// Telegram message id -> the task it announced; the newest ones, saved.
    public struct Book: Codable, Equatable, Sendable {
        public var tasks: [String: Task] = [:]
        public var order: [String] = []
        public static let keep = 100

        public init() {}

        public mutating func remember(_ task: Task, message: Int64) {
            let key = String(message)
            if tasks[key] == nil { order.append(key) }
            tasks[key] = task
            while order.count > Self.keep { tasks[order.removeFirst()] = nil }
        }

        public func task(for message: Int64) -> Task? { tasks[String(message)] }

        public static func load(from url: URL) -> Book {
            guard let data = try? Data(contentsOf: url),
                  let book = try? JSONDecoder().decode(Book.self, from: data) else { return Book() }
            return book
        }

        public func save(to url: URL) {
            guard let data = try? JSONEncoder().encode(self) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Short enough for a phone: whole lines while they fit, then "…".
    public static func excerpt(_ text: String?, limit: Int) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard text.count > limit else { return text }
        let cut = String(text.prefix(limit))
        let end = cut.lastIndex(where: { $0 == "\n" || $0 == "." }).map { cut[...$0] } ?? Substring(cut)
        return String(end.count > limit / 2 ? end : Substring(cut)).trimmingCharacters(in: .whitespacesAndNewlines) + " …"
    }

    /// The "done" message: what was asked, what the agent says it did, which
    /// files changed — so a reply can say what to do next.
    public static func finishedMessage(head: String, task: String?, summary: String?, files: [String],
                                       taskLabel: (String) -> String, filesLabel: (Int, String) -> String) -> String {
        var lines = [head]
        if let task = excerpt(task, limit: 200) { lines.append(taskLabel(task)) }
        if let summary = excerpt(summary, limit: 900) { lines += ["", summary] }
        if !files.isEmpty {
            let names = files.suffix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            lines += ["", filesLabel(files.count, names + (files.count > 3 ? ", …" : ""))]
        }
        return lines.joined(separator: "\n")
    }

    public static func clean(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
    }

    /// What the agent reads: plainly a new instruction from its user.
    public static func instruction(_ text: String) -> String {
        "The user replied from their phone (Telegram) with what to do next:\n\n" + text
    }

    /// A session id goes on a command line: never let it pass for an option.
    public static func isValidSession(_ id: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !id.isEmpty && id.count <= 128 && !id.hasPrefix("-") && id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// A reply too late for the waiting hook: the same session, resumed in the background.
    public static func continuation(_ task: Task, reply: String, now: Date = Date()) -> NightJob? {
        let text = clean(reply)
        guard !text.isEmpty, isValidSession(task.sessionId) else { return nil }
        return NightJob(agent: task.agent, folder: task.folder, prompt: instruction(text), trigger: .at(now),
                        createdAt: now, host: task.host, resume: task.sessionId)
    }
}
