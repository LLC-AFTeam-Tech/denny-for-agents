import Foundation

/// What `remote/denny-hook.py --report` prints: token counts per UTC hour,
/// agent and model, plus plan limits. Times are Unix seconds.
public struct UsageReport: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var hour: Double
        public var agent: AgentKind
        public var model: String
        public var project: String?
        public var input: Int
        public var cacheWrite5m: Int
        public var cacheWrite1h: Int
        public var cacheRead: Int
        public var output: Int

        public init(hour: Double, agent: AgentKind, model: String, project: String? = nil, input: Int = 0,
                    cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0, output: Int = 0) {
            self.hour = hour
            self.agent = agent
            self.model = model
            self.project = project
            self.input = input
            self.cacheWrite5m = cacheWrite5m
            self.cacheWrite1h = cacheWrite1h
            self.cacheRead = cacheRead
            self.output = output
        }

        public var totalTokens: Int { input + cacheWrite5m + cacheWrite1h + cacheRead + output }
        public var promptTokens: Int { input + cacheWrite5m + cacheWrite1h + cacheRead }
    }

    public struct Window: Codable, Equatable, Sendable {
        public var kind: String
        public var label: String?
        public var percent: Double
        public var resetsAt: Double?
        /// Set on the Mac: the reading is older than the window itself, so the
        /// real level is unknown (it has certainly renewed since).
        public var stale: Bool?

        public init(kind: String, label: String? = nil, percent: Double, resetsAt: Double? = nil, stale: Bool? = nil) {
            self.kind = kind
            self.label = label
            self.percent = percent
            self.resetsAt = resetsAt
            self.stale = stale
        }

        public var isStale: Bool { stale == true }

        public var length: TimeInterval { kind == "session" ? 5 * 3600 : 7 * 86400 }

        /// What this reading means now: a passed reset is a renewed (0%) window;
        /// a reading older than the window, with no reset time, is unknown.
        public func current(observedAt: Double, now: Double) -> Window {
            var window = self
            if let resetsAt, resetsAt <= now {
                window.percent = 0
                window.resetsAt = nil
                window.stale = nil
            } else if resetsAt == nil, now - observedAt > length {
                window.stale = true
            }
            return window
        }
    }

    public struct Limits: Codable, Equatable, Sendable {
        public var agent: AgentKind
        public var plan: String?
        /// Monthly list price of the plan in USD, when known.
        public var planPrice: Double?
        public var windows: [Window]
        public var observedAt: Double

        public init(agent: AgentKind, plan: String? = nil, planPrice: Double? = nil, windows: [Window], observedAt: Double) {
            self.agent = agent
            self.plan = plan
            self.planPrice = planPrice
            self.windows = windows
            self.observedAt = observedAt
        }
    }

    public struct Activity: Codable, Equatable, Sendable {
        public var agent: AgentKind
        public var at: Double
    }

    /// Codex's banked rate-limit resets, read live from `codex app-server`.
    public struct Resets: Codable, Equatable, Sendable {
        public var agent: AgentKind
        public var available: Int
        public var nextExpiresAt: Double?
        public var observedAt: Double
        public var host: String?

        public init(agent: AgentKind, available: Int, nextExpiresAt: Double? = nil, observedAt: Double, host: String? = nil) {
            self.agent = agent
            self.available = available
            self.nextExpiresAt = nextExpiresAt
            self.observedAt = observedAt
            self.host = host
        }
    }

    public var host: String
    public var generatedAt: Double
    public var usage: [Item]
    public var limits: [Limits]
    public var activity: [Activity]
    public var resets: [Resets]?
    public var system: System?

    /// Load of a Linux server, from /proc.
    public struct System: Codable, Equatable, Sendable {
        public var load1: Double
        public var load5: Double
        public var load15: Double
        public var cpus: Int
        public var memTotal: Double
        public var memAvailable: Double
        public var swapTotal: Double
        public var swapUsed: Double
        public var uptime: Double

        public var memoryUsedFraction: Double { memTotal > 0 ? 1 - memAvailable / memTotal : 0 }
        public var loadFraction: Double { cpus > 0 ? load1 / Double(cpus) : 0 }
        /// Less than a tenth of memory left: a heavy build may get killed.
        public var memoryLow: Bool { memTotal > 0 && memAvailable / memTotal < 0.1 }
    }

    public init(host: String, generatedAt: Double, usage: [Item] = [], limits: [Limits] = [], activity: [Activity] = [],
                resets: [Resets]? = nil) {
        self.host = host
        self.generatedAt = generatedAt
        self.usage = usage
        self.limits = limits
        self.activity = activity
        self.resets = resets
    }
}

/// Anthropic list prices per million tokens (Claude API, 2026-09-25).
/// Cache writes cost 1.25x input for 5 minutes and 2x for an hour. Models
/// missing here are left unpriced rather than guessed.
public enum Pricing {
    public struct Price: Equatable, Sendable {
        public let input: Double
        public let output: Double
        public let cacheRead: Double
    }

    static let table: [(prefix: String, price: Price)] = [
        ("claude-fable-5-1", Price(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", Price(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", Price(input: 10, output: 50, cacheRead: 1)),
        ("claude-mythos-5", Price(input: 10, output: 50, cacheRead: 1)),
        ("claude-opus-5-5", Price(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-opus-5", Price(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-8", Price(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-7", Price(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-6", Price(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-sonnet-5-5", Price(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-5", Price(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-4-6", Price(input: 3, output: 15, cacheRead: 0.3)),
        ("claude-haiku-4-5", Price(input: 1, output: 5, cacheRead: 0.1))
    ].sorted { $0.prefix.count > $1.prefix.count }

    /// Fresher prices downloaded by the app (prices.json); they win over the table.
    public static var overrides: [(prefix: String, price: Price)] = []

    public static func price(for model: String) -> Price? {
        let normalized = model.lowercased()
            .replacingOccurrences(of: "[1m]", with: "")
            .replacingOccurrences(of: ".", with: "-")
        return (overrides + table).first { normalized.hasPrefix($0.prefix) }?.price
    }

    /// `{"models": {"model-prefix": {"input": 4, "output": 20, "cacheRead": 0.2}}}`
    public static func overrides(fromJSON data: Data) -> [(prefix: String, price: Price)]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [String: Any] else { return nil }
        var result: [(prefix: String, price: Price)] = []
        for (prefix, value) in models {
            guard let fields = value as? [String: Any],
                  let input = (fields["input"] as? NSNumber)?.doubleValue,
                  let output = (fields["output"] as? NSNumber)?.doubleValue else { continue }
            let cacheRead = (fields["cacheRead"] as? NSNumber)?.doubleValue ?? input * 0.1
            let key = prefix.lowercased().replacingOccurrences(of: ".", with: "-")
            result.append((key, Price(input: input, output: output, cacheRead: cacheRead)))
        }
        return result.sorted { $0.prefix.count > $1.prefix.count }
    }

    public static func cost(_ item: UsageReport.Item) -> Double? {
        guard let price = price(for: item.model) else { return nil }
        let micro = Double(item.input) * price.input
            + Double(item.cacheWrite5m) * price.input * 1.25
            + Double(item.cacheWrite1h) * price.input * 2
            + Double(item.cacheRead) * price.cacheRead
            + Double(item.output) * price.output
        return micro / 1_000_000
    }
}

public enum UsagePeriod: String, CaseIterable, Sendable {
    case today
    case week
    case month
}

/// Everything the stats cards show, combined across this Mac and any
/// SSH servers that sent a report.
public struct UsageSummary: Equatable, Sendable {
    public struct Spend: Equatable, Sendable {
        public var cost: Double = 0
        /// False when some model had no known price: `cost` is a minimum.
        public var fullyPriced = true
        public var tokens = 0
        public var promptTokens = 0
        public var cacheRead = 0
        public var byAgent: [AgentKind: Double] = [:]
        public var tokensByAgent: [AgentKind: Int] = [:]

        public init() {}

        public var cacheShare: Double? {
            promptTokens > 0 ? Double(cacheRead) / Double(promptTokens) : nil
        }
    }

    public struct Day: Equatable, Sendable {
        public var start: Date
        public var tokens: Int
    }

    /// Local days of the activity map: 13 whole weeks ending this week.
    public var days: [Day] = []
    public var streak = 0
    public var activeDays = 0
    public var busiestDay: Day?

    public struct Share: Equatable, Sendable {
        public var name: String
        public var tokens: Int
        public var cost: Double
        public var fullyPriced: Bool
        public var agent: AgentKind
    }

    public struct Bar: Equatable, Sendable {
        public var start: Date
        public var cost: [AgentKind: Double]
        public var tokens: [AgentKind: Int]
    }

    /// Biggest first; models and projects for each period.
    public var models: [UsagePeriod: [Share]] = [:]
    public var projects: [UsagePeriod: [Share]] = [:]
    /// Today by hour, 7 and 30 days by day.
    public var trend: [UsagePeriod: [Bar]] = [:]

    public var limits: [AgentKind: UsageReport.Limits] = [:]
    public var resets: [AgentKind: UsageReport.Resets] = [:]
    public var lastActivity: [AgentKind: Date] = [:]
    public var spend: [UsagePeriod: Spend] = [:]
    public var agentsSeen: [AgentKind] = []

    public init() {}

    /// Every hour of today / every day of the period, empty ones included.
    static func filledBars(_ bars: [Date: Bar], period: UsagePeriod, starts: [UsagePeriod: Date], now: Date,
                           calendar: Calendar) -> [Bar] {
        guard var cursor = starts[period] else { return [] }
        let step: Calendar.Component = period == .today ? .hour : .day
        var result: [Bar] = []
        while cursor <= now {
            result.append(bars[cursor] ?? Bar(start: cursor, cost: [:], tokens: [:]))
            guard let next = calendar.date(byAdding: step, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    mutating func fillActivity(_ tokensByDay: [Date: Int], from start: Date, today: Date, calendar: Calendar) {
        var day = start
        while day <= today {
            days.append(Day(start: day, tokens: tokensByDay[day] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        let active = days.filter { $0.tokens > 0 }
        activeDays = active.count
        busiestDay = active.max { $0.tokens < $1.tokens }
        // Today only counts once it has some use, so a fresh morning doesn't break the streak.
        var index = days.count - 1
        if index >= 0, days[index].tokens == 0 { index -= 1 }
        streak = 0
        while index >= 0, days[index].tokens > 0 {
            streak += 1
            index -= 1
        }
    }

    public static func combine(_ reports: [UsageReport], now: Date = Date(), calendar: Calendar = .current) -> UsageSummary {
        var summary = UsageSummary()
        let startOfToday = calendar.startOfDay(for: now)
        let starts: [UsagePeriod: Date] = [
            .today: startOfToday,
            .week: calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday,
            .month: calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
        ]
        var seen = Set<AgentKind>()
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
        let mapStart = calendar.date(byAdding: .weekOfYear, value: -12, to: weekStart) ?? weekStart
        var tokensByDay: [Date: Int] = [:]
        var modelShares: [UsagePeriod: [String: Share]] = [:]
        var projectShares: [UsagePeriod: [String: Share]] = [:]
        var bars: [UsagePeriod: [Date: Bar]] = [:]

        for report in reports {
            for limits in report.limits where !limits.windows.isEmpty || limits.plan != nil {
                seen.insert(limits.agent)
                if let current = summary.limits[limits.agent], current.observedAt >= limits.observedAt { continue }
                summary.limits[limits.agent] = limits
            }
            for resets in report.resets ?? [] {
                if let current = summary.resets[resets.agent], current.observedAt >= resets.observedAt { continue }
                summary.resets[resets.agent] = resets
            }
            for activity in report.activity {
                seen.insert(activity.agent)
                let date = Date(timeIntervalSince1970: activity.at)
                if summary.lastActivity[activity.agent].map({ $0 < date }) ?? true {
                    summary.lastActivity[activity.agent] = date
                }
            }
            for item in report.usage {
                seen.insert(item.agent)
                let hour = Date(timeIntervalSince1970: item.hour)
                if hour >= mapStart {
                    tokensByDay[calendar.startOfDay(for: hour), default: 0] += item.totalTokens
                }
                let cost = Pricing.cost(item)
                for period in UsagePeriod.allCases {
                    // An hour bucket counts for a period if any of it falls inside.
                    guard let start = starts[period], hour.addingTimeInterval(3600) > start else { continue }
                    var spend = summary.spend[period] ?? Spend()
                    spend.tokens += item.totalTokens
                    spend.promptTokens += item.promptTokens
                    spend.cacheRead += item.cacheRead
                    spend.tokensByAgent[item.agent, default: 0] += item.totalTokens
                    if let cost {
                        spend.cost += cost
                        spend.byAgent[item.agent, default: 0] += cost
                    } else if item.totalTokens > 0 {
                        spend.fullyPriced = false
                    }
                    summary.spend[period] = spend

                    func add(_ name: String, to shares: inout [UsagePeriod: [String: Share]]) {
                        var share = shares[period, default: [:]][name]
                            ?? Share(name: name, tokens: 0, cost: 0, fullyPriced: true, agent: item.agent)
                        share.tokens += item.totalTokens
                        if let cost { share.cost += cost } else if item.totalTokens > 0 { share.fullyPriced = false }
                        shares[period, default: [:]][name] = share
                    }
                    add(item.model, to: &modelShares)
                    add(item.project.flatMap { $0.isEmpty ? nil : $0 } ?? item.agent.displayName, to: &projectShares)

                    let bucket = period == .today
                        ? calendar.dateInterval(of: .hour, for: hour)?.start ?? hour
                        : calendar.startOfDay(for: hour)
                    if bucket >= start {
                        var bar = bars[period, default: [:]][bucket] ?? Bar(start: bucket, cost: [:], tokens: [:])
                        bar.tokens[item.agent, default: 0] += item.totalTokens
                        if let cost { bar.cost[item.agent, default: 0] += cost }
                        bars[period, default: [:]][bucket] = bar
                    }
                }
            }
        }
        summary.agentsSeen = AgentKind.allCases.filter(seen.contains)
        let nowSeconds = now.timeIntervalSince1970
        for (agent, limits) in summary.limits {
            var current = limits
            current.windows = limits.windows.map { $0.current(observedAt: limits.observedAt, now: nowSeconds) }
            summary.limits[agent] = current
        }
        for period in UsagePeriod.allCases {
            summary.models[period] = (modelShares[period] ?? [:]).values.sorted { $0.tokens > $1.tokens }
            summary.projects[period] = (projectShares[period] ?? [:]).values.sorted { $0.tokens > $1.tokens }
            summary.trend[period] = Self.filledBars(bars[period] ?? [:], period: period, starts: starts, now: now,
                                                    calendar: calendar)
        }
        summary.fillActivity(tokensByDay, from: mapStart, today: startOfToday, calendar: calendar)
        return summary
    }
}
