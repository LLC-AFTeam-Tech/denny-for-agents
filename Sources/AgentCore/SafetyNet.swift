import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A copy of one file or folder that a command was about to delete.
public struct SafetyCopy: Codable, Equatable, Sendable {
    public var original: String
    /// Relative to the snapshot's folder.
    public var stored: String
}

/// Files as they were right before a destructive command. Same JSON as
/// `denny-hook.py` writes on a server.
public struct SafetySnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var createdAt: Double
    public var agent: String?
    public var cwd: String
    public var command: String
    /// Git top level and the hidden ref holding the working tree.
    public var repo: String?
    public var ref: String?
    public var copies: [SafetyCopy]
    /// Targets too big or unreadable to copy.
    public var skipped: [String]?
    public var host: String?
    /// Size of the copies (the git part lives in the repo itself).
    public var bytes: Int64?
}

/// How long snapshots live and how much room their copies may take. Chosen
/// in the app, read by the hooks; servers get it with the next message.
public struct SafetyNetSettings: Codable, Equatable, Sendable {
    public static let dayChoices = [1, 7, 30]
    public static let limitChoicesGB = [1, 2, 5, 10]

    public var days: Int
    public var limitMB: Int

    public init(days: Int = 7, limitMB: Int = 2048) {
        self.days = days
        self.limitMB = limitMB
    }

    public var maxAge: TimeInterval { TimeInterval(max(days, 1)) * 86400 }
    public var limitBytes: Int64 { Int64(max(limitMB, 100)) << 20 }

    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SafetyNetSettings {
        let url = SafetyNet.directory(home: home).appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(SafetyNetSettings.self, from: data) else { return SafetyNetSettings() }
        return settings
    }

    public func save(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let folder = SafetyNet.directory(home: home)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: folder.appendingPathComponent("settings.json"), options: .atomic)
    }
}

/// "Safety net": right before an agent runs rm, git reset --hard, git clean -f,
/// git checkout/restore over local changes or find -delete, the hook snapshots
/// the files. Inside a git repo the whole working tree, untracked files
/// included, goes into refs/denny/safety-net/<id> without touching the branch,
/// index or stash; targets outside git or git-ignored are copied aside.
/// Mirrors the safety net section of remote/denny-hook.py.
public enum SafetyNet {
    public static let refPrefix = "refs/denny/safety-net/"
    public static let keep = 50
    public static let copyFileLimit = 20000

    public static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        BridgePaths.directory(home: home).appendingPathComponent("safety-net", isDirectory: true)
    }

    // MARK: - Spotting destructive commands

    /// The whole shell command of a tool call, unclipped.
    public static func command(fromPayload data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let input = json["tool_input"] as? [String: Any] else { return nil }
        if let text = input["command"] as? String { return text }
        if let parts = input["command"] as? [Any] {
            let words = parts.compactMap { $0 as? String }
            if words.count == 3, words[1] == "-lc" || words[1] == "-c" { return words[2] }
            return words.isEmpty ? nil : words.joined(separator: " ")
        }
        return nil
    }

    /// Words of each simple command; operators and new lines split, quotes respected.
    static func segments(_ command: String) -> [[String]] {
        let text = command.replacingOccurrences(of: "\\\n", with: " ")
        var segments: [[String]] = [], words: [String] = [], word = ""
        var hasWord = false
        var quote: Character?
        var escaped = false
        func endWord() {
            if hasWord { words.append(word) }
            word = ""
            hasWord = false
        }
        func endSegment() {
            endWord()
            if !words.isEmpty { segments.append(words) }
            words = []
        }
        for char in text {
            if escaped {
                word.append(char)
                hasWord = true
                escaped = false
            } else if char == "\\" && quote != "'" {
                escaped = true
            } else if let open = quote {
                if char == open { quote = nil } else { word.append(char) }
            } else if char == "'" || char == "\"" {
                quote = char
                hasWord = true
            } else if char == ";" || char == "&" || char == "|" || char == "\n" {
                endSegment()
            } else if char == " " || char == "\t" {
                endWord()
            } else {
                word.append(char)
                hasWord = true
            }
        }
        endSegment()
        return segments
    }

    static func strippingPrefixes(_ words: [String]) -> [String] {
        var index = 0
        while index < words.count {
            let word = words[index]
            if let equals = word.firstIndex(of: "="), !word.hasPrefix("-"), isIdentifier(String(word[..<equals])) {
                index += 1
            } else if ["sudo", "command", "nohup", "time", "exec", "builtin"].contains(word) {
                index += 1
            } else {
                break
            }
        }
        return Array(words[index...])
    }

    private static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.first, first == "_" || first.isLetter else { return false }
        return text.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// Whether the command destroys files, and what rm was pointed at.
    public static func risky(_ command: String) -> (risky: Bool, targets: [String]) {
        var risky = false, targets: [String] = []
        for segment in segments(command) {
            let words = strippingPrefixes(segment)
            guard let first = words.first else { continue }
            let name = (first as NSString).lastPathComponent
            let rest = Array(words.dropFirst())
            switch name {
            case "xargs" where rest.contains("rm"):
                risky = true
            case "rm", "unlink", "rmdir":
                risky = true
                var optionsDone = false
                for word in rest {
                    if !optionsDone && word == "--" {
                        optionsDone = true
                    } else if optionsDone || !word.hasPrefix("-") {
                        targets.append(word)
                    }
                }
            case "find" where rest.contains("-delete"):
                risky = true
            case "git":
                var args = rest[...]
                while let option = args.first, option.hasPrefix("-") {
                    args = args.dropFirst(option == "-C" || option == "-c" ? 2 : 1)
                }
                guard let sub = args.first else { continue }
                let subArgs = Array(args.dropFirst())
                switch sub {
                case "reset" where subArgs.contains("--hard"):
                    risky = true
                case "clean" where subArgs.contains(where: { $0 == "--force" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("f")) }):
                    risky = true
                case "checkout" where subArgs.contains("--") || subArgs.contains(".") || subArgs.contains("-f") || subArgs.contains("--force"):
                    risky = true
                case "restore" where !subArgs.contains("--staged") || subArgs.contains("--worktree"):
                    risky = true
                default:
                    break
                }
            default:
                break
            }
        }
        return (risky, targets)
    }

    // MARK: - Taking a snapshot

    /// Runs right before the command. Returns nil for a harmless command or
    /// when there was nothing to save.
    public static func take(command: String?, cwd: String?, agent: String?,
                            now: Date = Date(), home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SafetySnapshot? {
        guard let command, let cwd else { return nil }
        let (isRisky, targets) = risky(command)
        var isDirectory: ObjCBool = false
        guard isRisky, FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        let folder = directory(home: home)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let id = formatter.string(from: now) + "-" + String(UUID().uuidString.lowercased().prefix(4))
        let short = String((command.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").first ?? "").prefix(200))

        let settings = SafetyNetSettings.load(home: home)
        var index = prune(load(home: home), now: now, maxAge: settings.maxAge, home: home)
        let repo = git(cwd, ["rev-parse", "--show-toplevel"])
        let ref = repo.flatMap { gitSnapshot(repo: $0, id: id, message: "Denny safety net: " + short, folder: folder) }

        var copies: [SafetyCopy] = [], skipped: [String] = []
        var copied: Int64 = 0
        let homePath = home.path
        for path in expand(targets, cwd: cwd) {
            if let repo, ref != nil, (path + "/").hasPrefix(repo.hasSuffix("/") ? repo : repo + "/"),
               git(repo, ["check-ignore", "-q", path]) == nil {
                continue  // tracked or untracked-but-not-ignored: already in the git snapshot
            }
            if path == "/" || path == homePath {
                skipped.append(path)
                continue
            }
            let size = treeSize(path, budget: settings.limitBytes)
            // Oldest snapshots make room; what can't fit at all is skipped.
            index = makeRoom(index, needed: copied + size, limit: settings.limitBytes, home: home)
            if used(index) + copied + size > settings.limitBytes {
                skipped.append(path)
                continue
            }
            let name = (path as NSString).lastPathComponent
            let stored = "\(copies.count)/\(name.isEmpty ? "root" : name)"
            let destination = folder.appendingPathComponent(id).appendingPathComponent(stored)
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try FileManager.default.copyItem(atPath: path, toPath: destination.path)
            } catch {
                skipped.append(path)
                continue
            }
            copied += size
            copies.append(SafetyCopy(original: path, stored: stored))
        }
        guard ref != nil || !copies.isEmpty else {
            save(index, home: home)
            return nil
        }
        let snapshot = SafetySnapshot(id: id, createdAt: now.timeIntervalSince1970, agent: agent, cwd: cwd,
                                      command: short, repo: ref != nil ? repo : nil, ref: ref, copies: copies,
                                      skipped: skipped, host: nil, bytes: copied)
        index.append(snapshot)
        save(Array(index.suffix(keep)), home: home, dropping: Array(index.dropLast(keep)))
        return snapshot
    }

    private static func gitSnapshot(repo: String, id: String, message: String, folder: URL) -> String? {
        guard let indexPath = git(repo, ["rev-parse", "--git-path", "index"]) else { return nil }
        let realIndex = indexPath.hasPrefix("/") ? indexPath : (repo as NSString).appendingPathComponent(indexPath)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let tempIndex = folder.appendingPathComponent("index-" + id).path
        defer { try? FileManager.default.removeItem(atPath: tempIndex) }
        if FileManager.default.fileExists(atPath: realIndex) {
            try? FileManager.default.copyItem(atPath: realIndex, toPath: tempIndex)
        }
        let env = ["GIT_INDEX_FILE": tempIndex,
                   "GIT_AUTHOR_NAME": "Denny for Agents", "GIT_AUTHOR_EMAIL": "denny@localhost",
                   "GIT_COMMITTER_NAME": "Denny for Agents", "GIT_COMMITTER_EMAIL": "denny@localhost"]
        guard git(repo, ["add", "-A"], env: env, timeout: 120) != nil,
              let tree = git(repo, ["write-tree"], env: env), !tree.isEmpty else { return nil }
        let head = git(repo, ["rev-parse", "--verify", "-q", "HEAD"])
        let parents = head.map { ["-p", $0] } ?? []
        guard let commit = git(repo, ["commit-tree", tree] + parents + ["-m", message], env: env), !commit.isEmpty,
              git(repo, ["update-ref", refPrefix + id, commit]) != nil else { return nil }
        return refPrefix + id
    }

    static func expand(_ targets: [String], cwd: String) -> [String] {
        var paths: [String] = []
        for target in targets {
            var path = (target as NSString).expandingTildeInPath
            if !path.hasPrefix("/") { path = (cwd as NSString).appendingPathComponent(path) }
            let matches = target.contains(where: { "*?[".contains($0) }) ? glob(path) : [path]
            for match in matches {
                let normalized = canonical(match)
                let exists = FileManager.default.fileExists(atPath: normalized)
                    || (try? FileManager.default.destinationOfSymbolicLink(atPath: normalized)) != nil
                if exists, !paths.contains(normalized) { paths.append(normalized) }
            }
        }
        return paths
    }

    /// Real path of the folder, the name itself untouched: a symlink being
    /// deleted stays the symlink, and /var vs /private/var match what git says.
    static func canonical(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        return name.isEmpty || name == "/" ? parent.path : parent.appendingPathComponent(name).path
    }

    private static func glob(_ pattern: String) -> [String] {
        var result = glob_t()
        defer { globfree(&result) }
        guard systemGlob(pattern, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { index in
            result.gl_pathv[index].map { String(cString: $0) }
        }
    }

    /// Bytes under path, stopping once past the budget or the file limit.
    static func treeSize(_ path: String, budget: Int64) -> Int64 {
        let fm = FileManager.default
        let attributes = try? fm.attributesOfItem(atPath: path)
        guard attributes?[.type] as? FileAttributeType == .typeDirectory else {
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let walker = fm.enumerator(at: URL(fileURLWithPath: path),
                                         includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0, count = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            count += 1
            total += Int64(values?.fileSize ?? 0)
            if total > budget || count > copyFileLimit { return budget + 1 }
        }
        return total
    }

    // MARK: - Index

    private struct IndexFile: Codable {
        var version = 1
        var snapshots: [SafetySnapshot]
    }

    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [SafetySnapshot] {
        let url = directory(home: home).appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(IndexFile.self, from: data) else { return [] }
        return file.snapshots
    }

    /// Bytes the copies of these snapshots take.
    public static func used(_ snapshots: [SafetySnapshot]) -> Int64 {
        snapshots.reduce(0) { $0 + ($1.bytes ?? 0) }
    }

    /// Drops the oldest snapshots until `needed` more bytes fit under the limit.
    static func makeRoom(_ snapshots: [SafetySnapshot], needed: Int64, limit: Int64, home: URL) -> [SafetySnapshot] {
        var kept = snapshots
        while !kept.isEmpty, used(kept) + needed > limit, needed <= limit {
            remove(kept.removeFirst(), home: home)
        }
        return kept
    }

    static func remove(_ snapshot: SafetySnapshot, home: URL) {
        if let repo = snapshot.repo, let ref = snapshot.ref { git(repo, ["update-ref", "-d", ref]) }
        try? FileManager.default.removeItem(at: directory(home: home).appendingPathComponent(snapshot.id))
    }

    /// Deletes every snapshot on this machine.
    public static func clearAll(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        load(home: home).forEach { remove($0, home: home) }
        save([], home: home)
    }

    static func save(_ snapshots: [SafetySnapshot], home: URL, dropping dropped: [SafetySnapshot] = []) {
        dropped.forEach { remove($0, home: home) }
        let folder = directory(home: home)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(IndexFile(snapshots: snapshots)) else { return }
        try? data.write(to: folder.appendingPathComponent("index.json"), options: .atomic)
    }

    /// Drops snapshots older than the chosen number of days.
    static func prune(_ snapshots: [SafetySnapshot], now: Date, maxAge: TimeInterval, home: URL) -> [SafetySnapshot] {
        var kept: [SafetySnapshot] = []
        for snapshot in snapshots {
            if now.timeIntervalSince1970 - snapshot.createdAt <= maxAge { kept.append(snapshot) } else { remove(snapshot, home: home) }
        }
        return kept
    }

    // MARK: - Restoring

    /// Paths a restore would bring back or overwrite.
    public static func preview(_ snapshot: SafetySnapshot) -> [String] {
        var paths: [String] = []
        if let repo = snapshot.repo, let ref = snapshot.ref {
            let listed = git(repo, ["ls-tree", "-r", "--name-only", ref]) ?? ""
            let changed = Set((git(repo, ["diff", "--name-only", ref]) ?? "").split(separator: "\n").map(String.init))
            for name in listed.split(separator: "\n").map(String.init) {
                let path = (repo as NSString).appendingPathComponent(name)
                if changed.contains(name) || !FileManager.default.fileExists(atPath: path) { paths.append(path) }
            }
        }
        paths += snapshot.copies.map(\.original)
        return paths
    }

    /// Puts files back. Files created after the snapshot are left alone; ones
    /// a copy would overwrite are moved aside into the snapshot's folder.
    @discardableResult
    public static func restore(_ snapshot: SafetySnapshot, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        if let repo = snapshot.repo, let ref = snapshot.ref {
            guard git(repo, ["restore", "--source=" + ref, "--worktree", "--overlay", "--", "."]) != nil
                    || git(repo, ["checkout", ref, "--", "."]) != nil else { return false }
        }
        let fm = FileManager.default
        let folder = directory(home: home).appendingPathComponent(snapshot.id)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let aside = folder.appendingPathComponent("replaced-" + formatter.string(from: Date()))
        for (index, copy) in snapshot.copies.enumerated() {
            let source = folder.appendingPathComponent(copy.stored).path
            guard fm.fileExists(atPath: source) || (try? fm.destinationOfSymbolicLink(atPath: source)) != nil else { continue }
            do {
                if fm.fileExists(atPath: copy.original) || (try? fm.destinationOfSymbolicLink(atPath: copy.original)) != nil {
                    try fm.createDirectory(at: aside, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try fm.moveItem(atPath: copy.original, toPath: aside.appendingPathComponent(String(index)).path)
                }
                try fm.createDirectory(atPath: (copy.original as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
                try fm.copyItem(atPath: source, toPath: copy.original)
            } catch {
                return false
            }
        }
        return true
    }

    /// For a snapshot taken on a server: what to run there.
    public static func restoreCommand(_ snapshot: SafetySnapshot) -> String {
        "python3 ~/.denny-for-agents/denny-hook.py --restore \(snapshot.id)"
    }

    // MARK: - git

    @discardableResult
    static func git(_ directory: String, _ args: [String], env: [String: String] = [:], timeout: TimeInterval = 60) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + args
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#if canImport(Darwin)
private func systemGlob(_ pattern: String, _ result: inout glob_t) -> Int32 {
    Darwin.glob(pattern, 0, nil, &result)
}
#else
private func systemGlob(_ pattern: String, _ result: inout glob_t) -> Int32 {
    Glibc.glob(pattern, 0, nil, &result)
}
#endif
