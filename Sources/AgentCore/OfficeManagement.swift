import Foundation

/// How the Office is run: second-opinion review, budgets, the morning stand-up
/// and recurring tasks. Saved next to the tasks.
public struct OfficeSettings: Codable, Equatable, Sendable {
    /// The other agent reviews each finished task before it goes to the boss.
    public var review = false
    /// Claude stops at this many dollars per task (its own `--max-budget-usd`).
    public var claudeBudget: Double?
    /// Codex has no public prices: it stops at this many thousand tokens
    /// (input + output, cache reads not counted).
    public var codexBudgetK: Int?
    /// The stand-up in Telegram at this hour; nil = off.
    public var standupHour: Int? = 9
    public var lastStandup: Date?
    public var recurring: [OfficeRecurring] = []

    public init() {}

    public static func file(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        BridgePaths.directory(home: home).appendingPathComponent("office-settings.json")
    }

    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> OfficeSettings {
        guard let data = try? Data(contentsOf: file(home: home)),
              let settings = try? JSONDecoder().decode(OfficeSettings.self, from: data) else { return OfficeSettings() }
        return settings
    }

    public func save(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        try? FileManager.default.createDirectory(at: BridgePaths.directory(home: home), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.file(home: home), options: .atomic)
    }
}

/// "Every Monday at 10, update the dependencies and run the tests."
public struct OfficeRecurring: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var prompt: String
    /// nil: Denny picks by the limits when it's time.
    public var agent: AgentKind?
    public var folder: String
    public var host: String?
    /// 1 = Sunday … 7 = Saturday (Calendar's numbering); nil = every day.
    public var weekday: Int?
    public var hour: Int
    public var lastRun: Date?

    public init(id: String = UUID().uuidString, prompt: String, agent: AgentKind?, folder: String, host: String? = nil,
                weekday: Int?, hour: Int) {
        self.id = id
        self.prompt = prompt
        self.agent = agent
        self.folder = folder
        self.host = host
        self.weekday = weekday
        self.hour = hour
    }

    /// Due once on its day, from its hour on (a Mac asleep at 10 catches up later that day).
    public func isDue(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour], from: now)
        if let weekday, parts.weekday != weekday { return false }
        guard (parts.hour ?? 0) >= hour else { return false }
        if let lastRun, calendar.isDate(lastRun, inSameDayAs: now) { return false }
        return true
    }
}

extension Office {
    /// "/task@MyBot fix the form" -> ("task", "fix the form"); only the Office's commands.
    public static func command(_ text: String) -> (name: String, rest: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let head = trimmed.prefix { !$0.isWhitespace }
        let name = head.dropFirst().split(separator: "@").first.map { String($0).lowercased() } ?? ""
        guard ["task", "board"].contains(name) else { return nil }
        return (name, String(trimmed.dropFirst(head.count)).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "Let Denny decide": whoever has more of the plan left right now; Claude
    /// when nothing is known. Only agents installed here count.
    public static func pickAgent(limits: [AgentKind: UsageReport.Limits], available: [AgentKind] = AgentKind.allCases) -> AgentKind {
        func used(_ agent: AgentKind) -> Double {
            (limits[agent]?.windows ?? []).filter { !$0.isStale }.map(\.percent).max() ?? 0
        }
        let candidates = available.isEmpty ? [AgentKind.claude] : available
        return candidates.min { used($0) < used($1) } ?? .claude
    }

    /// The budget part of the command line (Claude only; Codex is watched by tokens).
    public static func budgetArguments(agent: AgentKind, settings: OfficeSettings) -> [String] {
        guard agent == .claude, let budget = settings.claudeBudget, budget > 0 else { return [] }
        return ["--max-budget-usd", String(format: "%.2f", budget)]
    }

    /// Tokens that count against a Codex budget.
    public static func budgetTokens(_ usage: [UsageReport.Item]) -> Int {
        usage.reduce(0) { $0 + $1.input + $1.output + $1.cacheWrite5m + $1.cacheWrite1h }
    }

    /// Whether it's time for the stand-up (once a day, from its hour).
    public static func standupDue(_ settings: OfficeSettings, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let hour = settings.standupHour, (calendar.dateComponents([.hour], from: now).hour ?? 0) >= hour else { return false }
        if let last = settings.lastStandup, calendar.isDate(last, inSameDayAs: now) { return false }
        return true
    }

    /// The stand-up's numbers: the last day's work and what waits for the boss.
    public struct Standup: Equatable, Sendable {
        public var finished: [OfficeTask] = []
        public var waiting: [OfficeTask] = []
        public var working: [OfficeTask] = []
        public var queued = 0
        public var cost: Double = 0
        public var tokens = 0

        public var isEmpty: Bool { finished.isEmpty && waiting.isEmpty && working.isEmpty && queued == 0 }
    }

    public static func standup(_ tasks: [OfficeTask], since: Date) -> Standup {
        var result = Standup()
        for task in tasks {
            switch task.state {
            case .queued: result.queued += 1
            case .working: result.working.append(task)
            case .review: result.waiting.append(task)
            case .failed(let at, _): if at >= since { result.waiting.append(task) }
            case .accepted(let at), .discarded(let at): if at >= since { result.finished.append(task) }
            }
            if task.createdAt >= since || task.column != .done {
                result.cost += task.report?.cost ?? 0
                result.tokens += task.report?.tokens ?? 0
            }
        }
        return result
    }
}
