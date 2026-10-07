import Foundation

/// Work the Mac hands to the worker on a server (`denny-hook.py --worker`),
/// which asks for it through the forwarded port.
public struct RemoteJob: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case tests, review, lines, night, cancel
    }

    public var id: String
    public var kind: Kind
    public var cwd: String?
    public var files: [String]?
    /// Review: who made the changes, and what they were asked.
    public var author: AgentKind?
    public var task: String?
    /// Night shift.
    public var agent: AgentKind?
    public var prompt: String?
    public var resetsAt: Double?
    public var at: Double?
    /// Cancel: the night job to stop.
    public var target: String?

    public init(id: String = UUID().uuidString, kind: Kind, cwd: String? = nil, files: [String]? = nil,
                author: AgentKind? = nil, task: String? = nil, agent: AgentKind? = nil, prompt: String? = nil,
                resetsAt: Double? = nil, at: Double? = nil, target: String? = nil) {
        self.id = id
        self.kind = kind
        self.cwd = cwd
        self.files = files
        self.author = author
        self.task = task
        self.agent = agent
        self.prompt = prompt
        self.resetsAt = resetsAt
        self.at = at
        self.target = target
    }

    /// A night job for the server, with its trigger.
    public init(night job: NightJob) {
        var resetsAt: Double?, at: Double?
        switch job.trigger {
        case .limitRenews(let reset): resetsAt = reset
        case .at(let date): at = date.timeIntervalSince1970
        }
        self.init(id: job.id, kind: .night, cwd: job.folder, agent: job.agent, prompt: job.prompt, resetsAt: resetsAt, at: at)
    }
}

/// What the worker sends back. States: passed / failed / none (tests),
/// done / failed (review, lines), queued / running / done / failed (night).
public struct RemoteJobResult: Codable, Equatable, Sendable {
    public var id: String
    public var kind: RemoteJob.Kind
    public var state: String
    public var command: String?
    public var output: String?
    public var duration: Double?
    public var added: Int?
    public var removed: Int?
    public var reviewer: AgentKind?

    public init(id: String, kind: RemoteJob.Kind, state: String, command: String? = nil, output: String? = nil,
                duration: Double? = nil, added: Int? = nil, removed: Int? = nil, reviewer: AgentKind? = nil) {
        self.id = id
        self.kind = kind
        self.state = state
        self.command = command
        self.output = output
        self.duration = duration
        self.added = added
        self.removed = removed
        self.reviewer = reviewer
    }
}

/// app -> worker: the jobs waiting for that server.
public struct JobBatch: Codable, Equatable, Sendable {
    public var id: String
    public var jobs: [RemoteJob]

    public init(id: String, jobs: [RemoteJob]) {
        self.id = id
        self.jobs = jobs
    }
}
