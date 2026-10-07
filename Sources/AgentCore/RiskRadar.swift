import Foundation

/// How worried Denny is about what an agent asks to do.
public enum RiskLevel: Int, Comparable, Sendable {
    case safe
    case caution
    case danger
    case critical

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One reason, as a translation key (`risk.reason.<key>`) plus an optional
/// detail such as the path that would be deleted.
public struct RiskReason: Equatable, Sendable {
    public let key: String
    public let detail: String?
}

public struct RiskAssessment: Equatable, Sendable {
    public let level: RiskLevel
    /// Most serious first.
    public let reasons: [RiskReason]

    public static let safe = RiskAssessment(level: .safe, reasons: [])
}

/// Reads a permission request and explains, in plain words, what could go
/// wrong. Rules only — instant, offline, no model. It never decides: the
/// person always does.
public enum RiskRadar {
    private struct Rule {
        let level: RiskLevel
        let key: String
        let pattern: NSRegularExpression
        /// Capture group used as the detail, if any.
        let detailGroup: Int?

        init(_ level: RiskLevel, _ key: String, _ pattern: String, detail: Int? = nil) {
            self.level = level
            self.key = key
            self.pattern = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.detailGroup = detail
        }
    }

    private static let shellRules: [Rule] = [
        // Critical: hard or impossible to undo, or runs code from the internet.
        Rule(.critical, "pipeToShell", #"\b(curl|wget)\b[^|;&]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?|perl|ruby)\b"#),
        Rule(.critical, "wipeRoot", #"\brm\s+(-[a-z]*[rf][a-z]*\s+)+(--no-preserve-root\s+)?(/|~|\$HOME|/\*|~/\*|\*)(\s|$)"#),
        Rule(.critical, "rawDisk", #"\bdd\b[^;&|]*\bof=/dev/|>\s*/dev/(disk|sd|nvme)"#),
        Rule(.critical, "format", #"\b(mkfs(\.\w+)?|diskutil\s+(erase\w*|partitionDisk|zeroDisk))\b"#),
        Rule(.critical, "forkBomb", #":\(\)\s*\{\s*:\|:&\s*\};:"#),
        Rule(.critical, "dropData", #"\b(drop\s+(table|database|schema)|truncate\s+table)\b"#),
        // Danger: destroys work or reaches beyond the project.
        Rule(.danger, "deleteRecursive", #"\brm\s+(?:-[a-z]*r[a-z]*\s+|-[a-z]*\s+)*(?:--\s+)?([^\s;&|]+)"#, detail: 1),
        Rule(.danger, "forcePush", #"\bgit\s+push\b[^;&|]*(\s--force(-with-lease)?\b|\s-f\b)"#),
        Rule(.danger, "resetHard", #"\bgit\s+reset\s+[^;&|]*--hard\b"#),
        Rule(.danger, "cleanUntracked", #"\bgit\s+clean\s+-[a-z]*f"#),
        Rule(.danger, "sudo", #"(^|[;&|]\s*|\s)sudo\s"#),
        Rule(.danger, "permissions", #"\bchmod\s+(-R\s+)?0?777\b|\bchown\s+-R\b"#),
        Rule(.danger, "killProcess", #"\b(kill\s+-9|killall|pkill)\b"#),
        Rule(.danger, "reboot", #"\b(shutdown|reboot|halt)\b"#),
        Rule(.danger, "dockerPrune", #"\bdocker\s+(system\s+prune|volume\s+(rm|prune)|rm\s+-f)\b"#),
        Rule(.danger, "publish", #"\b(npm\s+publish|cargo\s+publish|twine\s+upload|gem\s+push|gh\s+release\s+create|pod\s+trunk\s+push)\b"#),
        Rule(.danger, "secrets", #"(\.ssh/|id_(rsa|ed25519)|\.aws/credentials|\.env\b|keychain|security\s+find-generic-password)"#),
        // Caution: fine most of the time, worth a glance.
        Rule(.caution, "push", #"\bgit\s+push\b"#),
        Rule(.caution, "deleteFile", #"\brm\s+(?:-[a-z]+\s+)*([^\s;&|-][^\s;&|]*)"#, detail: 1),
        Rule(.caution, "install", #"\b(npm\s+(i|install|add)|yarn\s+add|pnpm\s+add|pip3?\s+install|brew\s+install|apt(-get)?\s+install|gem\s+install|cargo\s+install)\b"#),
        Rule(.caution, "network", #"\b(curl|wget|scp|rsync|ssh)\b"#),
        Rule(.caution, "gitHistory", #"\bgit\s+(rebase|commit\s+--amend|checkout\s+--\s|restore\s)"#),
    ]

    private static let sensitivePaths = try! NSRegularExpression(
        pattern: #"(^|/)(\.ssh|\.aws|\.gnupg|\.config/gh)(/|$)|(^|/)\.env(\.|$)|^/(etc|usr|bin|sbin|System|Library)/|(^|/)\.(zshrc|bashrc|bash_profile|zprofile|profile)$|(^|/)(id_rsa|id_ed25519)"#,
        options: []
    )

    /// `clipped`: the input was shortened before it got here (a long remote
    /// command): what can't be seen can't be called safe.
    public static func assess(toolName: String?, toolInput: [String: JSONValue]?, clipped: Bool = false) -> RiskAssessment {
        let input = toolInput ?? [:]
        var reasons: [(RiskLevel, RiskReason)] = []
        if clipped { reasons.append((.danger, RiskReason(key: "clipped", detail: nil))) }

        if let command = StepDescriber.command(from: input) {
            reasons += assess(command: command)
        }
        switch StepDescriber.kind(toolName: toolName) {
        case .writing:
            // A patch can touch many files: every one counts, not just the first.
            let paths = [input["file_path"]?.stringValue, input["path"]?.stringValue, input["notebook_path"]?.stringValue]
                .compactMap { $0 } + patchedPaths(input)
            if let path = paths.first(where: isSensitive) {
                reasons.append((.danger, RiskReason(key: "sensitiveFile", detail: (path as NSString).lastPathComponent)))
            }
        default:
            break
        }
        if let name = toolName, name.hasPrefix("mcp__"), reasons.isEmpty {
            reasons.append((.caution, RiskReason(key: "externalTool", detail: nil)))
        }

        guard let top = reasons.map(\.0).max() else { return .safe }
        var seen = Set<String>()
        let ordered = reasons.sorted { $0.0 > $1.0 }.map(\.1).filter { seen.insert($0.key).inserted }
        return RiskAssessment(level: top, reasons: ordered)
    }

    static func assess(command: String) -> [(RiskLevel, RiskReason)] {
        var found: [(RiskLevel, RiskReason)] = []
        let range = NSRange(command.startIndex..., in: command)
        for rule in shellRules {
            guard let match = rule.pattern.firstMatch(in: command, range: range) else { continue }
            var detail: String?
            if let group = rule.detailGroup, let r = Range(match.range(at: group), in: command) {
                detail = String(command[r])
            }
            // "rm -rf build" also matches "rm build"; keep only the stronger one.
            if rule.key == "deleteFile", found.contains(where: { $0.1.key == "deleteRecursive" || $0.1.key == "wipeRoot" }) { continue }
            if rule.key == "deleteRecursive", found.contains(where: { $0.1.key == "wipeRoot" }) { continue }
            if rule.key == "deleteRecursive",
               command.range(of: #"\brm\s+(?:-[a-z]+\s+)*-[a-z]*r"#, options: [.regularExpression, .caseInsensitive]) == nil { continue }
            if rule.key == "push", found.contains(where: { $0.1.key == "forcePush" }) { continue }
            found.append((rule.level, RiskReason(key: rule.key, detail: detail)))
        }
        return found
    }

    static func isSensitive(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let range = NSRange(expanded.startIndex..., in: expanded)
        return sensitivePaths.firstMatch(in: expanded, range: range) != nil
    }

    /// Every file a patch adds, updates, deletes or moves to.
    static func patchedPaths(_ input: [String: JSONValue]) -> [String] {
        guard let patch = input["input"]?.stringValue ?? input["patch"]?.stringValue else { return [] }
        let markers = ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: "]
        return patch.split(separator: "\n").compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let marker = markers.first(where: { text.hasPrefix($0) }) else { return nil }
            let path = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : path
        }
    }
}
