import Foundation

/// "Is it really done?": finds how a project runs its tests, so Denny can
/// check an agent's work right after the task.
public enum TestRunner {
    /// One line at the project root overrides the guess, e.g. `npm run test:unit`.
    public static let customFile = ".denny-test"
    public static let timeout: TimeInterval = 10 * 60

    /// The project root (git top level, else the folder) and its test command.
    public static func detect(cwd: String) -> (root: String, command: String)? {
        let root = SafetyNet.git(cwd, ["rev-parse", "--show-toplevel"]) ?? cwd
        let fm = FileManager.default
        func path(_ name: String) -> String { (root as NSString).appendingPathComponent(name) }
        func has(_ name: String) -> Bool { fm.fileExists(atPath: path(name)) }
        func read(_ name: String) -> String? { try? String(contentsOfFile: path(name), encoding: .utf8) }

        if let custom = read(customFile)?.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) {
            return (root, custom)
        }
        if has("Package.swift") { return (root, "swift test") }
        if let data = read("package.json")?.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let script = (json["scripts"] as? [String: Any])?["test"] as? String,
           !script.contains("no test specified") {
            if has("bun.lockb") || has("bun.lock") { return (root, "bun run test") }
            if has("pnpm-lock.yaml") { return (root, "pnpm test") }
            if has("yarn.lock") { return (root, "yarn test") }
            return (root, "npm test")
        }
        if has("Cargo.toml") { return (root, "cargo test") }
        if has("go.mod") { return (root, "go test ./...") }
        let pyproject = read("pyproject.toml") ?? ""
        if has("pytest.ini") || has("conftest.py") || pyproject.contains("[tool.pytest")
            || (has("tests") && (has("pyproject.toml") || has("setup.py") || has("requirements.txt"))) {
            return (root, "python3 -m pytest -q")
        }
        if let makefile = read("Makefile"),
           makefile.split(separator: "\n").contains(where: { $0.hasPrefix("test:") }) {
            return (root, "make test")
        }
        return nil
    }

    /// The last lines of the output: what the agent needs to see.
    public static func tail(_ output: String, lines: Int = 40) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
