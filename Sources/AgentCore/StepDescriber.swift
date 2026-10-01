import Foundation

/// What kind of work a tool call is, for Denny's animations.
public enum StepKind: String, Equatable, Sendable {
    case writing
    case running
    case planning
    case reading
    case other
}

/// Turns a tool call into a short human line for the notch:
/// "Reads Package.swift", "Runs npm test", "Edits App.swift".
public enum StepDescriber {
    static let commandLimit = 60

    public static func describe(toolName: String?, toolInput: [String: JSONValue]?, language: UILanguage) -> String {
        let input = toolInput ?? [:]
        let name = toolName ?? ""
        let t = Texts(language: language)

        switch name {
        case "Bash", "shell", "exec_command", "local_shell":
            if let command = command(from: input) {
                return t.runs(shortCommand(command))
            }
            return t.runsCommand
        case "Read", "view_image":
            return t.reads(fileName(input) ?? t.aFile)
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch":
            if let file = fileName(input) ?? patchedFile(input) {
                return t.edits(file)
            }
            return t.editsFiles
        case "Grep", "Glob":
            if let pattern = input["pattern"]?.stringValue {
                return t.searches(shortCommand(pattern))
            }
            return t.searchesCode
        case "WebSearch", "web_search":
            return t.searchesWeb
        case "WebFetch":
            if let url = input["url"]?.stringValue, let host = URL(string: url)?.host {
                return t.opens(host)
            }
            return t.searchesWeb
        case "Task", "Agent", "spawn_agent":
            return t.startsHelper
        case "TodoWrite", "update_plan":
            return t.updatesPlan
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.split(separator: "_", omittingEmptySubsequences: true)
                if parts.count >= 3 {
                    return t.uses("\(parts[1]): \(parts[2...].joined(separator: "_"))")
                }
            }
            return name.isEmpty ? t.working : t.uses(name)
        }
    }

    public static func kind(toolName: String?) -> StepKind {
        switch toolName ?? "" {
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch": return .writing
        case "Bash", "shell", "exec_command", "local_shell": return .running
        case "TodoWrite", "update_plan": return .planning
        case "Read", "Grep", "Glob", "WebSearch", "WebFetch", "web_search", "view_image": return .reading
        default: return .other
        }
    }

    static func command(from input: [String: JSONValue]) -> String? {
        switch input["command"] {
        case .string(let text)?:
            return text
        case .array(let parts)?:
            let words = parts.compactMap(\.stringValue)
            // Codex wraps shell commands as ["bash", "-lc", "<command>"].
            if words.count == 3, words[1] == "-lc" || words[1] == "-c" {
                return words[2]
            }
            return words.isEmpty ? nil : words.joined(separator: " ")
        default:
            return nil
        }
    }

    static func shortCommand(_ command: String) -> String {
        let firstLine = command.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? command
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > commandLimit ? String(trimmed.prefix(commandLimit)) + "…" : trimmed
    }

    static func fileName(_ input: [String: JSONValue]) -> String? {
        for key in ["file_path", "notebook_path", "path"] {
            if let path = input[key]?.stringValue, !path.isEmpty {
                return (path as NSString).lastPathComponent
            }
        }
        return nil
    }

    /// The full path an apply_patch touches.
    static func patchedPath(_ input: [String: JSONValue]) -> String? {
        let patch = input["input"]?.stringValue ?? input["patch"]?.stringValue ?? input["command"]?.stringValue
        guard let patch else { return nil }
        for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] {
            if let range = patch.range(of: marker) {
                let path = patch[range.upperBound...].split(separator: "\n").first.map(String.init) ?? ""
                if !path.isEmpty { return path }
            }
        }
        return nil
    }

    static func patchedFile(_ input: [String: JSONValue]) -> String? {
        let patch = input["input"]?.stringValue ?? input["patch"]?.stringValue ?? input["command"]?.stringValue
        guard let patch else { return nil }
        for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] {
            if let range = patch.range(of: marker) {
                let rest = patch[range.upperBound...]
                let path = rest.split(separator: "\n").first.map(String.init) ?? ""
                if !path.isEmpty { return (path as NSString).lastPathComponent }
            }
        }
        return nil
    }
}

struct Texts {
    let language: UILanguage

    private func t(_ key: String, _ arguments: CVarArg...) -> String {
        Translations.format(key, language, arguments)
    }

    func runs(_ command: String) -> String { t("step.runs", command) }
    var runsCommand: String { t("step.runsCommand") }
    func reads(_ file: String) -> String { t("step.reads", file) }
    var aFile: String { t("step.aFile") }
    func edits(_ file: String) -> String { t("step.edits", file) }
    var editsFiles: String { t("step.editsFiles") }
    func searches(_ pattern: String) -> String { t("step.searches", pattern) }
    var searchesCode: String { t("step.searchesCode") }
    var searchesWeb: String { t("step.searchesWeb") }
    func opens(_ host: String) -> String { t("step.opens", host) }
    var startsHelper: String { t("step.startsHelper") }
    var updatesPlan: String { t("step.updatesPlan") }
    func uses(_ tool: String) -> String { t("step.uses", tool) }
    var working: String { t("step.working") }
    var thinking: String { t("step.thinking") }
    var waitingForYou: String { t("step.waitingForYou") }
    var done: String { t("step.done") }
}
