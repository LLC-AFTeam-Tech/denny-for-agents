import Foundation

/// Paths dropped on the notch, ready to paste into Claude Code or Codex.
public enum ShellQuote {
    private static let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@%:,")

    public static func quote(_ path: String) -> String {
        if !path.isEmpty, path.unicodeScalars.allSatisfy(safe.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func join(_ paths: [String]) -> String {
        paths.map(quote).joined(separator: " ")
    }
}
