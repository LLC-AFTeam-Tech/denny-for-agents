import AgentCore
import Foundation

struct DropMessage: Equatable {
    var title: String
    var warning: String?
}

enum NotchMode: Equatable {
    case hidden
    case compact
    /// The notch drops for a few seconds to show Denny at work.
    case peek
    case expanded
}

final class AgentsViewModel: ObservableObject {
    @Published var mode: NotchMode = .hidden
    @Published var notchHeight: CGFloat = 32
    @Published var sessions: [AgentSession] = []
    @Published var approvals: [PendingApproval] = []
    @Published var mood: AgentMood = .idle
    @Published var serverRunning = true
    @Published var hooksInstalled = true
    @Published var summary = UsageSummary()
    @Published var period: UsagePeriod = .today
    @Published var now = Date()
    @Published var peekActivity: DennyActivity?
    @Published var dropTargeted = false
    @Published var dropMessage: DropMessage?
    /// This Mac has Codex, so a reset credit can be spent from here.
    @Published var canResetCodex = false
    @Published var resettingCodex = false

    var limitAlmostUsed: Bool { tightestLimit != nil }

    /// The fullest window of any agent, whatever its level.
    var restingLimit: (agent: AgentKind, window: UsageReport.Window)? {
        var best: (agent: AgentKind, window: UsageReport.Window)?
        for (agent, limits) in summary.limits {
            for window in limits.windows where best.map({ window.percent > $0.window.percent }) ?? true {
                best = (agent, window)
            }
        }
        return best
    }

    /// The most recently active working session that has a running turn.
    var currentTurn: (agent: AgentKind, start: Date)? {
        sessions
            .filter { $0.status == .working }
            .compactMap { session in session.turnStartedAt.map { (session.agent, $0, session.updatedAt) } }
            .max { $0.2 < $1.2 }
            .map { ($0.0, $0.1) }
    }

    /// The fullest window at 90% or more, for the header.
    var tightestLimit: (agent: AgentKind, window: UsageReport.Window)? {
        var best: (agent: AgentKind, window: UsageReport.Window)?
        for (agent, limits) in summary.limits {
            for window in limits.windows where window.percent >= 90 {
                if best.map({ window.percent > $0.window.percent }) ?? true { best = (agent, window) }
            }
        }
        return best
    }

    /// Denny at the laptop while an agent writes code, at the notebook while it plans.
    var headerActivity: DennyActivity? {
        guard let session = sessions.first(where: { $0.status == .working }) else { return nil }
        switch session.stepKind {
        case .writing?: return .notes
        case .planning?: return .tasks
        default: return nil
        }
    }

    var workingAgents: Set<AgentKind> {
        Set(sessions.filter { $0.status == .working || $0.status == .waitingApproval }.map(\.agent))
    }

    func update(from store: AgentStore) {
        sessions = store.orderedSessions
        approvals = store.approvals
        mood = store.mood
        now = Date()
    }
}

/// UI strings, looked up in AgentCore's translation tables (Strings/*.swift).
struct L {
    static let language = UILanguage.current

    private static func t(_ key: String, _ arguments: CVarArg...) -> String {
        Translations.format(key, language, arguments)
    }

    static var idleTitle: String { t("title.idle") }
    static var workingTitle: String { t("title.working") }
    static var needsYouTitle: String { t("title.needsYou") }
    static var noSessions: String { t("subtitle.noSessions") }
    static var noHooks: String { t("subtitle.noHooks") }
    static var serverDown: String { t("subtitle.serverDown") }
    static var allow: String { t("approval.allow") }
    static var deny: String { t("approval.deny") }
    static var askThere: String { t("approval.askThere") }
    static var wantsTo: String { t("approval.wantsTo") }
    static func moreApprovals(_ count: Int) -> String { t("approval.more", count) }
    static var fullDenny: String { t("fullDenny") }

    static var spending: String { t("stats.spending") }
    static var apiValue: String { t("stats.apiValue") }
    static var now: String { t("stats.now") }
    static var workingNow: String { t("stats.workingNow") }
    static var limitsLater: String { t("stats.limitsLater") }
    static func updated(_ when: String) -> String { t("stats.updated", when) }
    static func tokens(_ count: String) -> String { t("stats.tokens", count) }
    static var tokensWord: String { t("stats.tokensWord") }
    static func fromCache(_ percent: Int) -> String { t("stats.fromCache", percent) }
    static func todayTotal(_ cost: String) -> String { t("stats.todayTotal", cost) }
    static var noPrice: String { t("stats.noPrice") }
    static func period(_ period: UsagePeriod) -> String {
        switch period {
        case .today: return t("period.today")
        case .week: return t("period.week")
        case .month: return t("period.month")
        }
    }
    static func windowName(_ window: UsageReport.Window) -> String {
        let base: String
        switch window.kind {
        case "session": base = t("window.session")
        case "weekly": base = t("window.week")
        default: return window.label ?? t("window.limit")
        }
        return window.label.map { "\(base) · \($0)" } ?? base
    }
    static var activity: String { t("stats.activity") }
    static func streak(_ days: Int) -> String { t("stats.streak", days) }
    static var activeDays: String { t("stats.activeDays") }
    static var busiestDay: String { t("stats.busiestDay") }

    static func daysHours(_ d: Int, _ h: Int) -> String { t("time.daysHours", d, h) }
    static func hoursMinutes(_ h: Int, _ m: Int) -> String { t("time.hoursMinutes", h, m) }
    static func minutesOnly(_ m: Int) -> String { t("time.minutes", m) }
    static func hoursOnly(_ h: Int) -> String { t("time.hours", h) }
    static func daysOnly(_ d: Int) -> String { t("time.days", d) }
    static func monthsOnly(_ m: Int) -> String { t("time.months", m) }
    static var justNow: String { t("time.justNow") }
    static func ago(_ span: String) -> String { t("time.ago", span) }

    static func limitTitle(_ agent: AgentKind, used: Double) -> String {
        t(used >= 100 ? "title.limitUsedUp" : "title.limitAlmost", agent == .claude ? "Claude" : "Codex")
    }
    static func limitDetail(_ window: UsageReport.Window, resetsIn: String?) -> String {
        let base = "\(windowName(window)) \(Int(window.percent.rounded()))%"
        guard let resetsIn else { return base }
        return t("limit.detailResets", base, resetsIn)
    }

    static func resetsLine(_ count: Int) -> String { t("resets.line", count) }
    static func expiresIn(_ span: String) -> String { t("resets.expiresIn", span) }
    static var useReset: String { t("resets.use") }
    static var resetting: String { t("resets.resetting") }
    static var resetConfirmTitle: String { t("resets.confirmTitle") }
    static func resetConfirmBody(_ left: Int) -> String { t("resets.confirmBody", left) }
    static func resetOutcome(_ outcome: String) -> String {
        switch outcome {
        case "reset": return t("resets.outcome.reset")
        case "nothingToReset": return t("resets.outcome.nothing")
        case "noCredit": return t("resets.outcome.noCredit")
        case "alreadyRedeemed": return t("resets.outcome.already")
        default: return t("resets.outcome.failed")
        }
    }

    static var dropHere: String { t("drop.here") }
    static func copiedPaths(_ count: Int, _ name: String) -> String {
        count == 1 ? t("drop.copiedOne", name) : t("drop.copiedMany", count)
    }
    static func remoteCantSee(_ host: String) -> String { t("drop.remoteCantSee", host) }
    static func willSend(_ count: Int, _ host: String) -> String {
        count == 1 ? t("drop.willSendOne", host) : t("drop.willSendMany", count, host)
    }
    static func delivered(_ count: Int, _ host: String) -> String { t("drop.delivered", host, count) }
    static var skippedFolders: String { t("drop.skippedFolders") }
    static var tooBig: String { t("drop.tooBig") }
    static var shelfInFullDenny: String { t("drop.shelfInFullDenny") }

    static var menuAlerts: String { t("alerts.menu") }
    static var alertFinish: String { t("alerts.finish") }
    static var alertLimit: String { t("alerts.limit") }
    static var alertBudget: String { t("alerts.budget") }
    static var off: String { t("alerts.off") }
    static var anyLength: String { t("alerts.anyLength") }
    static func longerThan(_ minutes: Int) -> String { t("alerts.longerThan", minutes) }
    static func atPercent(_ percent: Int) -> String { t("alerts.atPercent", percent) }
    static func finishedTitle(_ agent: AgentKind) -> String { t("alerts.finishedTitle", agent.displayName) }
    static func finishedBody(_ project: String, _ duration: String) -> String { t("alerts.finishedBody", project, duration) }
    static func limitAlertTitle(_ agent: AgentKind, _ percent: Int) -> String {
        t("alerts.limitTitle", agent == .claude ? "Claude" : "Codex", percent)
    }
    static func budgetAlertTitle(_ spent: String) -> String { t("alerts.budgetTitle", spent) }
    static var budgetAlertBody: String { t("alerts.budgetBody") }

    static var menuClaude: String { t("menu.claude") }
    static var menuCodex: String { t("menu.codex") }
    static var menuRemote: String { t("menu.remote") }
    static var menuFullDenny: String { t("menu.fullDenny") }
    static var menuQuit: String { t("menu.quit") }
    static var remoteTitle: String { t("remote.title") }
    static func remoteBody(port: UInt16) -> String {
        Translations.text("remote.body", language).replacingOccurrences(of: "{port}", with: String(port))
    }
    static var copyCommand: String { t("remote.copy") }
    static var remoteUnavailable: String { t("remote.unavailable") }
    static var close: String { t("common.close") }
    static var cancel: String { t("common.cancel") }

    static var connectTitle: String { t("connect.title") }
    static var connectBody: String { t("connect.body") }
    static var connect: String { t("connect.connect") }
    static var later: String { t("connect.later") }
    static var setupFailed: String { t("connect.failed") }
}
