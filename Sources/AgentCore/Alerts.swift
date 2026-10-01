import Foundation

/// When Denny should send a macOS notification. `nil` turns a rule off.
public struct AlertSettings: Codable, Equatable, Sendable {
    /// Notify about finished turns at least this long; 0 = every turn.
    public var finishAfterMinutes: Int?
    public var limitPercent: Int?
    public var dailyBudget: Double?

    public init(finishAfterMinutes: Int? = 2, limitPercent: Int? = 80, dailyBudget: Double? = nil) {
        self.finishAfterMinutes = finishAfterMinutes
        self.limitPercent = limitPercent
        self.dailyBudget = dailyBudget
    }

    public func notifiesFinish(after duration: TimeInterval?) -> Bool {
        guard let minutes = finishAfterMinutes else { return false }
        guard let duration else { return minutes == 0 }
        return duration >= TimeInterval(minutes * 60)
    }
}

/// Remembers which alerts were already sent so each fires once: a limit
/// once per window period, the budget once per day.
public struct AlertTracker: Equatable, Sendable {
    public static let maxRemembered = 200

    public private(set) var sent: [String]

    public init(sent: [String] = []) {
        self.sent = sent
    }

    public mutating func limitAlerts(_ summary: UsageSummary, settings: AlertSettings) -> [(agent: AgentKind, window: UsageReport.Window)] {
        guard let threshold = settings.limitPercent else { return [] }
        var alerts: [(agent: AgentKind, window: UsageReport.Window)] = []
        for agent in AgentKind.allCases {
            for window in summary.limits[agent]?.windows ?? [] where !window.isStale && window.percent >= Double(threshold) {
                // A new period (new reset time) may alert again.
                let period = window.resetsAt.map { String(Int($0 / 3600)) } ?? "?"
                if remember("limit|\(agent.rawValue)|\(window.kind)|\(window.label ?? "")|\(threshold)|\(period)") {
                    alerts.append((agent, window))
                }
            }
        }
        return alerts
    }

    public mutating func budgetAlert(spentToday: Double, settings: AlertSettings, day: String) -> Bool {
        guard let budget = settings.dailyBudget, spentToday >= budget else { return false }
        return remember("budget|\(day)|\(budget)")
    }

    private mutating func remember(_ key: String) -> Bool {
        guard !sent.contains(key) else { return false }
        sent.append(key)
        if sent.count > Self.maxRemembered { sent.removeFirst(sent.count - Self.maxRemembered) }
        return true
    }
}

/// Spots a limit window that just renewed: it was high and is now far lower.
public enum LimitRenewal {
    public static let wasAtLeast: Double = 80
    public static let droppedBy: Double = 50

    public static func key(_ agent: AgentKind, _ window: UsageReport.Window) -> String {
        "\(agent.rawValue)|\(window.kind)|\(window.label ?? "")"
    }

    /// Returns the renewed windows and the levels to remember for next time.
    public static func detect(previous: [String: Double], summary: UsageSummary)
        -> (renewed: [(agent: AgentKind, window: UsageReport.Window)], levels: [String: Double]) {
        var levels = previous
        var renewed: [(agent: AgentKind, window: UsageReport.Window)] = []
        for agent in AgentKind.allCases {
            for window in summary.limits[agent]?.windows ?? [] where !window.isStale {
                let key = key(agent, window)
                if let before = previous[key], before >= wasAtLeast, window.percent <= before - droppedBy {
                    renewed.append((agent, window))
                }
                levels[key] = window.percent
            }
        }
        return (renewed, levels)
    }
}
