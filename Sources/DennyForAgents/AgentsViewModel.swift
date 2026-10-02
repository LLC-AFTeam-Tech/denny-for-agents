import AgentCore
import Foundation

enum ReadoutKind: String {
    /// The current task's timer while an agent works, the tightest limit at rest.
    case timer
    /// Always the tightest limit.
    case limit
}

/// Card and readout choices from the menu bar, kept in UserDefaults.
enum ViewSettings {
    private static let defaults = UserDefaults.standard

    static var visibleCards: Set<StatsCardKind> {
        get { AppSettings.shared.visibleCards }
        set { AppSettings.shared.visibleCards = newValue }
    }

    static var page: NotchPage {
        get { defaults.string(forKey: "page").flatMap(NotchPage.init(rawValue:)) ?? .overview }
        set { defaults.set(newValue.rawValue, forKey: "page") }
    }

    static var readout: ReadoutKind {
        get { AppSettings.shared.readout }
        set { AppSettings.shared.readout = newValue }
    }
}

/// What the notch shows when it drops for a moment.
enum PeekContent: Equatable {
    case activity(DennyActivity)
    case finished(title: String, detail: String)
    /// An agent finished its task: its own celebration clip.
    case celebration(agent: AgentKind, title: String, detail: String)
}

/// A snapshot the hook just took; host is set when it lives on a server.
struct SafetyNetNotice: Equatable {
    let snapshot: SafetySnapshot
    let host: String?
}

/// Tests run after a task, shown on its receipt.
struct TestRun: Equatable {
    enum State: Equatable {
        case running
        case passed
        case failed(output: String)
    }

    let receiptId: String
    let command: String
    let startedAt: Date
    var state: State
    var duration: TimeInterval?
}

/// The other agent reviewing a task's changes, read-only.
struct ReviewRun: Equatable {
    enum State: Equatable {
        case running
        case done(text: String, findings: Int)
        case failed(String)
    }

    let receiptId: String
    let author: AgentKind
    let reviewer: AgentKind
    let startedAt: Date
    var state: State
}

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
    @Published var peek: PeekContent?
    /// A short reaction clip over Denny's loop.
    @Published var reaction: DennyReactionPlay?
    @Published var relayOffer: RelayOffer?
    /// The latest safety-net snapshot, shown as a card until hidden.
    @Published var safetyNet: SafetyNetNotice?
    /// The last finished task's receipt, shown as a card until hidden.
    @Published var receipt: TaskReceipt?
    /// How the receipt's project runs its tests, if Denny can run them here.
    @Published var receiptTestCommand: String?
    @Published var testRun: TestRun?
    /// The other agent, when it can review the receipt's changes here.
    @Published var reviewer: AgentKind?
    @Published var review: ReviewRun?
    @Published var visibleCards: Set<StatsCardKind> = ViewSettings.visibleCards
    @Published var readout: ReadoutKind = ViewSettings.readout
    @Published var page: NotchPage = ViewSettings.page
    /// The open notch is capped in height; past the cap its content scrolls.
    @Published var needsScroll = false
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
            for window in limits.windows where !window.isStale && (best.map({ window.percent > $0.window.percent }) ?? true) {
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
            for window in limits.windows where !window.isStale && window.percent >= 90 {
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
    static let language = AppSettings.launchLanguage

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

    static var noFreshData: String { t("stats.noFresh") }

    static var settingsTitle: String { t("settings.title") }
    static func phoneRequestText(_ approval: PendingApproval) -> String {
        let place = approval.projectName + (approval.host.map { " · " + $0 } ?? "")
        var lines = ["🛡️ " + t("phone.request", approval.agent.displayName, place), approval.summary]
        if let detail = approval.detail, !detail.isEmpty { lines.append(detail) }
        if approval.risk.level != .safe {
            lines.append("⚠️ " + riskLevel(approval.risk.level) + (approval.risk.reasons.first.map { ": " + riskReason($0) } ?? ""))
        }
        return lines.joined(separator: "\n")
    }
    static var phoneAllow: String { t("phone.allow") }
    static var phoneDeny: String { t("phone.deny") }
    static var phoneAllowed: String { t("phone.allowed") }
    static var phoneDenied: String { t("phone.denied") }
    static var phoneExpired: String { t("phone.expired") }
    static var phoneBadToken: String { t("phone.badToken") }
    static var phonePaired: String { t("phone.paired") }
    static var phoneTitle: String { t("phone.title") }
    static var phoneSteps: String { t("phone.steps") }
    static var phoneTokenPlaceholder: String { t("phone.tokenPlaceholder") }
    static var phoneCheck: String { t("phone.check") }
    static func phoneSendCode(_ bot: String) -> String { t("phone.sendCode", bot) }
    static var phoneOpenBot: String { t("phone.openBot") }
    static var phoneTopicHint: String { t("phone.topicHint") }
    static var phoneWaiting: String { t("phone.waiting") }
    static func phoneConnected(_ name: String, _ bot: String) -> String { t("phone.connected", name, bot) }
    static var phoneWhenAway: String { t("phone.whenAway") }
    static var phoneAlways: String { t("phone.always") }
    static var phoneFinished: String { t("phone.finished") }
    static var phoneTest: String { t("phone.test") }
    static var phoneTestText: String { t("phone.testText") }
    static var phoneDisconnect: String { t("phone.disconnect") }
    static var phoneFooter: String { t("phone.footer") }
    static var nightNewJob: String { t("night.newJob") }
    static var nightAgent: String { t("night.agent") }
    static var nightNoFolder: String { t("night.noFolder") }
    static var nightChooseFolder: String { t("night.chooseFolder") }
    static var nightWhen: String { t("night.when") }
    static var nightWhenRenews: String { t("night.whenRenews") }
    static var nightWhenAt: String { t("night.whenAt") }
    static var nightQueue: String { t("night.queue") }
    static var nightQueueTitle: String { t("night.queueTitle") }
    static func nightWaitsUntil(_ time: String) -> String { t("night.waitsUntil", time) }
    static var nightWaitsForLimit: String { t("night.waitsForLimit") }
    static func nightRunning(_ time: String) -> String { t("night.running", time) }
    static func nightDoneAt(_ time: String) -> String { t("night.doneAt", time) }
    static func nightFailedShort(_ reason: String) -> String { t("night.failedShort", reason) }
    static var nightFooter: String { t("night.footer") }
    static var nightInterrupted: String { t("night.interrupted") }
    static func nightStarted(_ agent: AgentKind, _ place: String) -> String { t("night.started", agent.displayName, place) }
    static func nightDone(_ agent: AgentKind, _ place: String) -> String { t("night.done", agent.displayName, place) }
    static func nightFailed(_ agent: AgentKind, _ place: String, _ reason: String) -> String { t("night.failed", agent.displayName, place, reason) }
    static func riskLevel(_ level: RiskLevel) -> String {
        switch level {
        case .safe: return t("risk.safe")
        case .caution: return t("risk.caution")
        case .danger: return t("risk.danger")
        case .critical: return t("risk.critical")
        }
    }
    static func riskReason(_ reason: RiskReason) -> String {
        t("risk.reason." + reason.key, reason.detail ?? "")
    }
    static var thisMac: String { t("load.thisMac") }
    static var cpu: String { t("load.cpu") }
    static func cpuLoad(_ cores: Int) -> String { t("load.cpuLoad", cores) }
    static var memory: String { t("load.memory") }
    static func pressure(_ level: Int) -> String {
        t(level >= 4 ? "load.pressureCritical" : (level >= 2 ? "load.pressureWarning" : "load.pressureNormal"))
    }
    static func swap(_ value: String) -> String { t("load.swap", value) }
    static func upFor(_ span: String) -> String { t("load.uptime", span) }
    static var memoryLowWarning: String { t("load.memoryLow") }
    static var noServerLoad: String { t("load.noServer") }
    static func relayTitle(_ agent: AgentKind, until: String?) -> String {
        until.map { t("relay.titleUntil", agent.displayName, $0) } ?? t("relay.title", agent.displayName)
    }
    static func relayBody(_ agent: AgentKind) -> String { t("relay.body", agent.displayName) }
    static func relayCopy(_ agent: AgentKind) -> String { t("relay.copy", agent.displayName) }
    static var relayLater: String { t("relay.later") }
    static func relayCopied(_ agent: AgentKind) -> String { t("relay.copied", agent.displayName) }
    static func relayHandoff(_ agent: AgentKind) -> String { t("relay.handoff", agent.displayName) }
    static func stuckTitle(_ agent: AgentKind) -> String { t("stuck.title", agent.displayName) }
    static func stuckReason(_ reason: StuckReason) -> String {
        switch reason {
        case .repeatedCommand(let command, let times): return t("stuck.repeatCommand", times, command)
        case .repeatedEdit(let file, let times): return t("stuck.repeatEdit", times, file)
        case .noProgress(let minutes): return t("stuck.noProgress", minutes)
        }
    }
    static var stuckSetting: String { t("stuck.setting") }
    static var quietOn: String { t("quiet.on") }
    static func quietActive(_ time: String) -> String { t("quiet.active", time) }
    static var refreshNow: String { t("quick.refresh") }
    static var awakeManual: String { t("awake.manual") }
    static var awakeDuration: String { t("awake.duration") }
    static var awakeUntil: String { t("awake.until") }
    static var awakeIndefinite: String { t("awake.indefinite") }
    static var awakeStart: String { t("awake.start") }
    static var awakeStop: String { t("awake.stop") }
    static func awakeActiveUntil(_ time: String) -> String { t("awake.activeUntil", time) }
    static var awakeUntilOff: String { t("awake.untilOff") }
    static var lidClosed: String { t("awake.lid") }
    static var lidWarning: String { t("awake.lidWarning") }
    static var lidNeedsPower: String { t("awake.lidNeedsPower") }
    static var menuSettings: String { t("settings.menu") }
    static var safetyPeekTitle: String { t("safety.peekTitle") }
    static var safetyCardTitle: String { t("safety.cardTitle") }
    static var safetyCardBody: String { t("safety.cardBody") }
    static func safetyOnServer(_ host: String) -> String { t("safety.onServer", host) }
    static var safetyUndo: String { t("safety.undo") }
    static var safetyCopyCommand: String { t("safety.copyCommand") }
    static var safetyHide: String { t("safety.hide") }
    static func safetyConfirmTitle(_ command: String) -> String { t("safety.confirmTitle", command) }
    static func safetyConfirmBody(_ count: Int) -> String { t("safety.confirmBody", count) }
    static var safetyConfirmRestore: String { t("safety.confirmRestore") }
    static var safetyNothing: String { t("safety.nothing") }
    static var safetyRestored: String { t("safety.restored") }
    static var safetyFailed: String { t("safety.failed") }
    static var safetyCommandCopied: String { t("safety.commandCopied") }
    static var safetyEmpty: String { t("safety.empty") }
    static var safetyFooter: String { t("safety.footer") }
    static var safetyStorage: String { t("safety.storage") }
    static var safetyKeepFor: String { t("safety.keepFor") }
    static func safetyKeep(_ days: Int) -> String { t("safety.keep.\(days)") }
    static var safetyLimit: String { t("safety.limit") }
    static func safetyGB(_ gb: Int) -> String { t("safety.gb", gb) }
    static func safetyUsed(_ size: String) -> String { t("safety.used", size) }
    static var safetyClear: String { t("safety.clear") }
    static var safetyClearConfirm: String { t("safety.clearConfirm") }
    static var safetyClearBody: String { t("safety.clearBody") }
    static var safetyDelete: String { t("safety.delete") }
    static var safetyLimitFooter: String { t("safety.limitFooter") }
    static var receiptTitle: String { t("receipt.title") }
    static func receiptFiles(_ count: Int) -> String { t("receipt.files", count) }
    static func receiptLines(_ added: Int, _ removed: Int) -> String { t("receipt.lines", added, removed) }
    static func receiptCommands(_ count: Int) -> String { t("receipt.commands", count) }
    static func receiptTokens(_ tokens: String) -> String { t("receipt.tokens", tokens) }
    static func receiptCost(_ cost: String) -> String { t("receipt.cost", cost) }
    static var receiptCopy: String { t("receipt.copy") }
    static var receiptCopied: String { t("receipt.copied") }
    static var receiptHide: String { t("receipt.hide") }
    static var receiptSignature: String { t("receipt.signature") }
    static var testsRun: String { t("tests.run") }
    static func testsRunning(_ command: String) -> String { t("tests.running", command) }
    static func testsPassed(_ duration: String) -> String { t("tests.passed", duration) }
    static func testsFailed(_ duration: String) -> String { t("tests.failed", duration) }
    static var testsSendToAgent: String { t("tests.sendToAgent") }
    static var testsCopied: String { t("tests.copied") }
    static func testsAgentMessage(_ command: String, _ output: String) -> String { t("tests.agentMessage", command, output) }
    static var testsAutoSetting: String { t("tests.autoSetting") }
    static var testsAutoFooter: String { t("tests.autoFooter") }
    static var testsTimedOut: String { t("tests.timedOut") }
    static func reviewButton(_ agent: AgentKind) -> String { t("review.button", agent.shortName) }
    static func reviewRunning(_ agent: AgentKind, _ time: String) -> String { t("review.running", agent.shortName, time) }
    static func reviewClean(_ agent: AgentKind) -> String { t("review.clean", agent.shortName) }
    static func reviewFindings(_ agent: AgentKind, _ count: Int) -> String { t("review.findings", agent.shortName, count) }
    static func reviewSend(_ agent: AgentKind) -> String { t("review.send", agent.shortName) }
    static func reviewCopied(_ agent: AgentKind) -> String { t("review.copied", agent.shortName) }
    static func reviewFailed(_ agent: AgentKind, _ reason: String) -> String { t("review.failed", agent.shortName, reason) }
    static var reviewNoChanges: String { t("review.noChanges") }
    static var reviewNotFound: String { t("review.notFound") }
    static func reviewAgentMessage(_ reviewer: AgentKind, _ text: String) -> String { t("review.agentMessage", reviewer.shortName, text) }
    static func settingsSection(_ section: SettingsSection) -> String { t("settings.section." + section.rawValue) }
    static var connected: String { t("settings.connected") }
    static var notConnected: String { t("settings.notConnected") }
    static var disconnect: String { t("settings.disconnect") }
    static var agentsFooter: String { t("settings.agentsFooter") }
    static var keepAwake: String { t("settings.keepAwake") }
    static var keepAwakeFooter: String { t("settings.keepAwakeFooter") }
    static var serversConnected: String { t("settings.serversConnected") }
    static var noServers: String { t("settings.noServers") }
    static func lastSeen(_ when: String) -> String { t("settings.lastSeen", when) }
    static var peeksTitle: String { t("settings.peeks") }
    static var peekOnStart: String { t("settings.peekOnStart") }
    static var peekOnWriting: String { t("settings.peekOnWriting") }
    static var peekOnFinish: String { t("settings.peekOnFinish") }
    static var displayTitle: String { t("settings.display") }
    static var displayAuto: String { t("settings.displayAuto") }
    static var showInFullScreen: String { t("settings.fullScreen") }
    static var cardsFooter: String { t("settings.cardsFooter") }
    static var languageSystem: String { t("settings.languageSystem") }
    static var languageRestart: String { t("settings.languageRestart") }
    static var restartNow: String { t("settings.restart") }
    static var privacyReads: String { t("settings.privacyReads") }
    static var privacyReadsBody: String { t("settings.privacyReadsBody") }
    static var privacyNever: String { t("settings.privacyNever") }
    static var privacyNeverBody: String { t("settings.privacyNeverBody") }
    static var removeAll: String { t("settings.removeAll") }
    static var removeAllFooter: String { t("settings.removeAllFooter") }
    static var removeAllConfirmTitle: String { t("settings.removeAllConfirm") }
    static func version(_ value: String) -> String { t("settings.version", value) }
    static var updateCheck: String { t("update.check") }
    static var updateChecking: String { t("update.checking") }
    static var updateUpToDate: String { t("update.upToDate") }
    static func updateAvailable(_ version: String) -> String { t("update.available", version) }
    static var updateInstall: String { t("update.install") }
    static var updateInstalling: String { t("update.installing") }
    static func updateFailed(_ reason: String) -> String { t("update.failed", reason) }
    static var updateOffline: String { t("update.reason.offline") }
    static var updateBadChecksum: String { t("update.reason.checksum") }
    static var updateNoPermission: String { t("update.reason.folder") }
    static var updateDownloadFailed: String { t("update.reason.download") }
    static var updateHomebrew: String { t("update.homebrew") }
    static var updateNotifyBody: String { t("update.notifyBody") }
    static var aboutBody: String { t("settings.about") }
    static var pageOverview: String { t("page.overview") }
    static var pageStats: String { t("page.stats") }
    static var valueTitle: String { t("value.title") }
    static func valueLine(_ cost: String) -> String { t("value.line", cost) }
    static func planMonthly(_ plan: String, _ price: String) -> String { t("value.planMonthly", plan, price) }
    static var trend: String { t("stats.trend") }
    static var models: String { t("stats.models") }
    static var projects: String { t("stats.projects") }
    static func peak(_ value: String) -> String { t("stats.peak", value) }
    static func renewedTitle(_ agent: AgentKind) -> String { t("alerts.renewedTitle", agent == .claude ? "Claude" : "Codex") }
    static var menuCards: String { t("menu.cards") }
    static var menuReadout: String { t("menu.readout") }
    static var readoutTimer: String { t("readout.timer") }
    static var readoutLimit: String { t("readout.limit") }
    static func cardName(_ card: StatsCardKind) -> String {
        switch card {
        case .limits: return t("card.limits")
        case .spending: return spending
        case .now: return now
        case .value: return valueTitle
        case .trend: return trend
        case .models: return models
        case .projects: return projects
        case .activity: return activity
        }
    }

    static var connectTitle: String { t("connect.title") }
    static var connectBody: String { t("connect.body") }
    static var connect: String { t("connect.connect") }
    static var later: String { t("connect.later") }
    static var setupFailed: String { t("connect.failed") }
}
