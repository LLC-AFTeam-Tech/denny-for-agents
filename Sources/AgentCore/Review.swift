import Foundation

/// Cross-review: the other agent reads what this one just changed, in
/// read-only mode, and lists what's wrong. Claude checks Codex, Codex checks Claude.
public enum CrossReview {
    public static let timeout: TimeInterval = 10 * 60
    public static let maxDiff = 120_000

    public static func reviewer(for agent: AgentKind) -> AgentKind { agent == .claude ? .codex : .claude }

    /// The git top level of a folder, or the folder itself outside git.
    public static func projectRoot(cwd: String) -> String {
        SafetyNet.git(cwd, ["rev-parse", "--show-toplevel"]) ?? cwd
    }

    /// The diff of the task's files against the last commit, new files in full.
    /// Outside git there's nothing to diff against: the files as they are now.
    public static func diff(cwd: String, files: [String]) -> String? {
        guard !files.isEmpty else { return nil }
        guard let repo = SafetyNet.git(cwd, ["rev-parse", "--show-toplevel"]) else { return wholeFiles(files, cwd: cwd) }
        var text = SafetyNet.git(repo, ["diff", "HEAD", "--"] + files) ?? ""
        let untracked = SafetyNet.git(repo, ["ls-files", "--others", "--exclude-standard", "--full-name", "--"] + files) ?? ""
        for name in untracked.split(separator: "\n").map(String.init) where !name.isEmpty {
            let path = (repo as NSString).appendingPathComponent(name)
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            text += "\n\nNew file \(name):\n" + content
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count > maxDiff { text = String(text.prefix(maxDiff)) + "\n\n[diff cut here: too long]" }
        return text
    }

    static func wholeFiles(_ files: [String], cwd: String) -> String? {
        var text = ""
        for file in files {
            let path = file.hasPrefix("/") ? file : (cwd as NSString).appendingPathComponent(file)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  (attributes[.size] as? Int ?? 0) < 2 << 20,
                  let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            text += "\n\nFile \(file) (outside git, as it is now):\n" + content
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count > maxDiff { text = String(text.prefix(maxDiff)) + "\n\n[cut here: too long]" }
        return text
    }

    public static func prompt(author: AgentKind, task: String?, diff: String) -> String {
        let asked = task.map { "The task was: «\($0)»." } ?? "The task description isn't available."
        return """
        You are reviewing changes that another AI coding agent (\(author.displayName)) has just made in this project. \(asked)

        Review them like a careful senior engineer: bugs, regressions, missed edge cases, security problems, \
        and anything that doesn't do what was asked. Don't edit any files — only read. You may open other files \
        of the project for context.

        Reply with a short list of concrete findings, most important first, one per line starting with "- ", \
        each with the file and line. If everything looks right, reply with one line saying so and nothing else. \
        Write the review in the same language as the task description.

        The changes (a git diff against the last commit; files outside git are shown in full, as they are now):

        \(diff)
        """
    }

    /// Lines that look like findings ("- ", "* ", "1. ").
    public static func findings(in review: String) -> Int {
        review.split(separator: "\n").filter { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("• ") { return true }
            guard let dot = text.firstIndex(of: "."), dot > text.startIndex else { return false }
            return text[..<dot].allSatisfy(\.isNumber) && text[text.index(after: dot)...].hasPrefix(" ")
        }.count
    }

    /// The headless command line of the reviewer, read-only.
    public static func arguments(reviewer: AgentKind, prompt: String) -> [String] {
        switch reviewer {
        case .codex: return ["exec", "--sandbox", "read-only", "--skip-git-repo-check", prompt]
        case .claude:
            return ["-p", prompt, "--allowedTools", "Read,Grep,Glob",
                    "--disallowedTools", "Edit,Write,MultiEdit,NotebookEdit,Bash"]
        }
    }

    /// Where the reviewer's command line tool usually lives.
    public static func candidates(_ agent: AgentKind, home: String = NSHomeDirectory()) -> [String] {
        switch agent {
        case .codex:
            return ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex",
                    home + "/.npm-global/bin/codex", "/Applications/ChatGPT.app/Contents/Resources/codex",
                    "/Applications/Codex.app/Contents/Resources/codex"]
        case .claude:
            return [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude",
                    "/usr/local/bin/claude", home + "/.npm-global/bin/claude"]
        }
    }
}
