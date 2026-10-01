import AgentCore
import AppKit
import Combine

/// Every user choice, in one place, saved to UserDefaults. The notch and the
/// settings window both read and write here.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var visibleCards: Set<StatsCardKind> {
        didSet { defaults.set(visibleCards.map(\.rawValue), forKey: "visibleCards") }
    }
    @Published var readout: ReadoutKind {
        didSet { defaults.set(readout.rawValue, forKey: "readout") }
    }
    @Published var peekOnStart: Bool {
        didSet { defaults.set(peekOnStart, forKey: "peekOnStart") }
    }
    @Published var peekOnFinish: Bool {
        didSet { defaults.set(peekOnFinish, forKey: "peekOnFinish") }
    }
    @Published var peekOnWriting: Bool {
        didSet { defaults.set(peekOnWriting, forKey: "peekOnWriting") }
    }
    /// The screen's localized name, or nil for "the one with a notch".
    @Published var display: String? {
        didSet { defaults.set(display, forKey: "display") }
    }
    @Published var showInFullScreen: Bool {
        didSet { defaults.set(showInFullScreen, forKey: "showInFullScreen") }
    }
    /// Hold off idle sleep while an agent on this Mac is working.
    @Published var keepAwake: Bool {
        didSet { defaults.set(keepAwake, forKey: "keepAwake") }
    }
    /// Manual "stay awake" until this moment; .distantFuture = until turned off.
    @Published var awakeUntil: Date? {
        didSet { defaults.set(awakeUntil?.timeIntervalSince1970, forKey: "awakeUntil") }
    }
    /// Keep working with the lid closed (charger only), see LidSleepGuard.
    @Published var keepAwakeLidClosed: Bool {
        didSet { defaults.set(keepAwakeLidClosed, forKey: "keepAwakeLidClosed") }
    }
    /// Warn when an agent seems to be going in circles.
    @Published var stuckAlerts: Bool {
        didSet { defaults.set(stuckAlerts, forKey: "stuckAlerts") }
    }
    /// Quiet mode: no peeks and no notifications until this moment.
    @Published var quietUntil: Date?
    /// nil follows the system language. Applied on the next launch.
    @Published var language: UILanguage? {
        didSet { defaults.set(language?.rawValue, forKey: "language") }
    }

    private init() {
        if let raw = defaults.stringArray(forKey: "visibleCards") {
            visibleCards = Set(raw.compactMap(StatsCardKind.init(rawValue:)))
        } else {
            visibleCards = Set(StatsCardKind.allCases)
        }
        readout = defaults.string(forKey: "readout").flatMap(ReadoutKind.init(rawValue:)) ?? .timer
        peekOnStart = defaults.object(forKey: "peekOnStart") as? Bool ?? true
        peekOnFinish = defaults.object(forKey: "peekOnFinish") as? Bool ?? true
        peekOnWriting = defaults.object(forKey: "peekOnWriting") as? Bool ?? true
        display = defaults.string(forKey: "display")
        showInFullScreen = defaults.object(forKey: "showInFullScreen") as? Bool ?? true
        keepAwake = defaults.object(forKey: "keepAwake") as? Bool ?? true
        awakeUntil = (defaults.object(forKey: "awakeUntil") as? Double).map(Date.init(timeIntervalSince1970:))
        keepAwakeLidClosed = defaults.bool(forKey: "keepAwakeLidClosed")
        stuckAlerts = defaults.object(forKey: "stuckAlerts") as? Bool ?? true
        language = defaults.string(forKey: "language").flatMap(UILanguage.init(rawValue:))
    }

    var isQuiet: Bool { quietUntil.map { $0 > Date() } ?? false }

    var manualAwakeActive: Bool { awakeUntil.map { $0 > Date() } ?? false }

    /// Language for this launch: the saved choice, else the system's.
    static var launchLanguage: UILanguage {
        UserDefaults.standard.string(forKey: "language").flatMap(UILanguage.init(rawValue:)) ?? .current
    }
}
