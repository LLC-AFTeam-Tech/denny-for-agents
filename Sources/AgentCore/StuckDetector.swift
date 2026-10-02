import Foundation

public struct StepRecord: Equatable, Sendable {
    public let at: Date
    public let kind: StepKind
    /// The whole command or the file name the step was about, if any.
    public let target: String?
}

public enum StuckReason: Equatable, Sendable {
    case repeatedCommand(command: String, times: Int)
    case repeatedEdit(file: String, times: Int)
    case noProgress(minutes: Int)

    /// One warning per command / file / kind per turn.
    public var id: String {
        switch self {
        case .repeatedCommand(let command, _): return "command|" + command
        case .repeatedEdit(let file, _): return "edit|" + file
        case .noProgress: return "noProgress"
        }
    }
}

/// Spots an agent going in circles from its tool calls in the current turn:
/// the same command over and over, the same file edited again and again, or
/// a long busy stretch without a single change.
public enum StuckDetector {
    public static let window: TimeInterval = 15 * 60
    public static let commandRepeats = 3
    public static let editRepeats = 6
    public static let idleMinutes = 20
    public static let idleMinSteps = 30

    static func target(toolName: String?, input: [String: JSONValue]) -> String? {
        switch StepDescriber.kind(toolName: toolName) {
        case .running:
            // The whole command: heredoc scripts often share their first line.
            return StepDescriber.command(from: input)?.trimmingCharacters(in: .whitespacesAndNewlines)
        case .writing:
            let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue ?? input["notebook_path"]?.stringValue
                ?? StepDescriber.patchedPath(input)
            return path.map { ($0 as NSString).lastPathComponent }
        default:
            return nil
        }
    }

    public static func check(_ history: [StepRecord], turnStartedAt: Date?, now: Date) -> StuckReason? {
        let recent = history.filter { now.timeIntervalSince($0.at) <= window }
        guard let last = recent.last, let target = last.target else {
            return noProgress(history, turnStartedAt: turnStartedAt, now: now)
        }
        let same = recent.filter { $0.kind == last.kind && $0.target == target }.count
        if last.kind == .running, same >= commandRepeats {
            return .repeatedCommand(command: StepDescriber.shortCommand(target), times: same)
        }
        if last.kind == .writing, same >= editRepeats {
            return .repeatedEdit(file: target, times: same)
        }
        return noProgress(history, turnStartedAt: turnStartedAt, now: now)
    }

    private static func noProgress(_ history: [StepRecord], turnStartedAt: Date?, now: Date) -> StuckReason? {
        guard let start = turnStartedAt else { return nil }
        let minutes = Int(now.timeIntervalSince(start) / 60)
        guard minutes >= idleMinutes else { return nil }
        let lastStretch = history.filter { now.timeIntervalSince($0.at) <= TimeInterval(idleMinutes * 60) }
        guard lastStretch.count >= idleMinSteps, !lastStretch.contains(where: { $0.kind == .writing }) else { return nil }
        return .noProgress(minutes: minutes)
    }
}
