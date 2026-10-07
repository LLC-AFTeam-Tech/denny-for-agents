import Foundation

/// What one finished task cost and changed — the "receipt" Denny shows.
public struct TaskReceipt: Equatable, Sendable, Identifiable {
    public var id: String { sessionKey + "|" + String(finishedAt.timeIntervalSince1970) }
    public let sessionKey: String
    public let agent: AgentKind
    public let projectName: String
    public let cwd: String?
    public let host: String?
    public let duration: TimeInterval?
    public let finishedAt: Date
    /// Full paths of the files the agent edited in this task.
    public let files: [String]
    public let commands: Int
    /// Tokens of this task by model (Claude Code only, from its transcript).
    public let usage: [UsageReport.Item]
    /// What the user asked for, for a cross-review.
    public var prompt: String?
    /// Filled in later for local projects with git.
    public var added: Int?
    public var removed: Int?

    public var tokens: Int {
        usage.reduce(0) { $0 + $1.input + $1.cacheWrite5m + $1.cacheWrite1h + $1.cacheRead + $1.output }
    }

    /// Nil when some model has no public price.
    public var cost: Double? {
        guard !usage.isEmpty else { return nil }
        var total = 0.0
        for item in usage {
            guard let cost = Pricing.cost(item) else { return nil }
            total += cost
        }
        return total
    }
}

public enum TurnUsage {
    public static let tailBytes = 8 << 20

    public static func transcriptPath(fromPayload data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["transcript_path"] as? String
    }

    /// Tokens of the last task in a Claude Code transcript: everything after
    /// the latest prompt the user typed. Streamed replies log one request
    /// several times, so each request counts once at its largest reading.
    public static func claude(transcript path: String) -> [UsageReport.Item] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        handle.seek(toFileOffset: start)
        var lines = handle.readDataToEndOfFile().split(separator: 0x0A)
        if start > 0, !lines.isEmpty { lines.removeFirst() }

        var readings: [String: (model: String, values: [Int])] = [:]
        var order: [String] = []
        for line in lines {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if isPrompt(entry) {
                readings = [:]
                order = []
                continue
            }
            guard entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let model = message["model"] as? String, !model.hasPrefix("<"),
                  let usage = message["usage"] as? [String: Any] else { continue }
            let split = usage["cache_creation"] as? [String: Any] ?? [:]
            let writeTotal = int(usage["cache_creation_input_tokens"])
            let write1h = int(split["ephemeral_1h_input_tokens"])
            var write5m = int(split["ephemeral_5m_input_tokens"])
            if write1h + write5m < writeTotal { write5m = writeTotal - write1h }
            let values = [int(usage["input_tokens"]), write5m, write1h, int(usage["cache_read_input_tokens"]), int(usage["output_tokens"])]
            let key = entry["requestId"] as? String ?? message["id"] as? String ?? UUID().uuidString
            if let seen = readings[key] {
                readings[key] = (model, zip(seen.values, values).map { max($0, $1) })
            } else {
                readings[key] = (model, values)
                order.append(key)
            }
        }
        var byModel: [String: [Int]] = [:]
        var models: [String] = []
        for key in order {
            guard let reading = readings[key] else { continue }
            if byModel[reading.model] == nil { models.append(reading.model) }
            byModel[reading.model] = zip(byModel[reading.model] ?? [0, 0, 0, 0, 0], reading.values).map { $0 + $1 }
        }
        return models.compactMap { model in
            guard let v = byModel[model] else { return nil }
            return UsageReport.Item(hour: 0, agent: .claude, model: model, input: v[0], cacheWrite5m: v[1],
                                    cacheWrite1h: v[2], cacheRead: v[3], output: v[4])
        }
    }

    /// The Codex session log: the hook's transcript_path, else found by session id
    /// under ~/.codex/sessions/YYYY/MM/DD (recent days first).
    public static func codexRollout(payload data: Data, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let path = json["transcript_path"] as? String, FileManager.default.fileExists(atPath: path) { return path }
        guard let session = json["session_id"] as? String, !session.isEmpty, !session.contains("/") else { return nil }
        let sessions = home.appendingPathComponent(".codex/sessions")
        let suffix = "-\(session).jsonl"
        let calendar = Calendar(identifier: .gregorian)
        for daysAgo in 0..<3 {
            let day = calendar.dateComponents([.year, .month, .day], from: Date().addingTimeInterval(-Double(daysAgo) * 86400))
            let folder = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0))
            if let name = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.first(where: { $0.hasSuffix(suffix) }) {
                return folder.appendingPathComponent(name).path
            }
        }
        guard let walker = FileManager.default.enumerator(atPath: sessions.path) else { return nil }
        for case let name as String in walker where name.hasSuffix(suffix) {
            return sessions.appendingPathComponent(name).path
        }
        return nil
    }

    /// Where a Codex task starts. Codex marks tasks itself (task_started); the
    /// prompt is only a fallback and has been written three ways: event_msg
    /// user_message (old), response_item message role=user and event_msg
    /// item_completed with a UserMessage item (current). Mirrors codex_boundary.
    enum CodexBoundary { case task, prompt }

    static func codexBoundary(_ entry: [String: Any], _ payload: [String: Any]) -> CodexBoundary? {
        let kind = entry["type"] as? String, item = payload["type"] as? String
        if kind == "event_msg", item == "task_started" || item == "turn_started" { return .task }
        if kind == "event_msg", item == "user_message" { return .prompt }
        if kind == "response_item", item == "message", payload["role"] as? String == "user" { return .prompt }
        if kind == "event_msg", item == "item_completed",
           (payload["item"] as? [String: Any])?["type"] as? String == "UserMessage" { return .prompt }
        return nil
    }

    /// A long task can push its start out of the usual tail: look further back
    /// before giving up. Mirrors CODEX_TAIL_STEPS.
    public static let codexTailSteps: [Int] = [tailBytes, 64 << 20, 512 << 20]

    /// Tokens of the last task in a Codex rollout: the running totals after its
    /// start minus the totals before it. Mirrors codex_turn_usage in denny-hook.py.
    public static func codex(rollout path: String, tailSteps: [Int] = codexTailSteps) -> [UsageReport.Item] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        for step in tailSteps {
            let start = size > UInt64(step) ? size - UInt64(step) : 0
            handle.seek(toFileOffset: start)
            var lines = handle.readDataToEndOfFile().split(separator: 0x0A)
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            let (seen, usage) = codexUsage(lines)
            if seen || start == 0 { return usage }
        }
        return []
    }

    static func codexUsage(_ lines: [Data.SubSequence]) -> (seen: Bool, usage: [UsageReport.Item]) {
        func reading(_ usage: Any?) -> [Int] {
            let usage = usage as? [String: Any] ?? [:]
            return [int(usage["input_tokens"]), int(usage["cached_input_tokens"]), int(usage["output_tokens"]),
                    int(usage["cache_write_input_tokens"])]
        }
        var model = "codex", base = [0, 0, 0, 0], last: [Int]?, summed = [0, 0, 0, 0]
        var seen = false, tasksMarked = false
        for line in lines {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = entry["payload"] as? [String: Any] else { continue }
            let type = entry["type"] as? String
            if type == "turn_context", let name = payload["model"] as? String {
                model = name
                continue
            }
            let boundary = codexBoundary(entry, payload)
            // With task markers present, a prompt is part of the task: one
            // message written in two formats mustn't restart the count.
            if boundary == .task || (boundary == .prompt && !tasksMarked) {
                tasksMarked = tasksMarked || boundary == .task
                base = last ?? [0, 0, 0, 0]
                summed = [0, 0, 0, 0]
                seen = true
            } else if type == "event_msg", payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any] {
                if info["total_token_usage"] is [String: Any] { last = reading(info["total_token_usage"]) }
                if seen, info["last_token_usage"] is [String: Any] {
                    summed = zip(summed, reading(info["last_token_usage"])).map { $0 + $1 }
                }
            }
        }
        guard seen, let last else { return (seen, []) }
        var delta = zip(last, base).map { $0 - $1 }
        if delta.contains(where: { $0 < 0 }) { delta = summed }  // totals restarted after a compaction
        guard delta.contains(where: { $0 > 0 }) else { return (seen, []) }
        let cached = min(delta[1], delta[0])
        // OpenAI counts cached tokens inside input_tokens.
        return (seen, [UsageReport.Item(hour: 0, agent: .codex, model: model, input: delta[0] - cached,
                                        cacheWrite5m: delta[3], cacheRead: cached, output: delta[2])])
    }

    /// A line the user typed (not a tool result or a meta line).
    static func isPrompt(_ entry: [String: Any]) -> Bool {
        guard entry["type"] as? String == "user", entry["isMeta"] as? Bool != true,
              let message = entry["message"] as? [String: Any] else { return false }
        if let text = message["content"] as? String { return !text.isEmpty }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.contains { $0["type"] as? String == "text" }
        }
        return false
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}

public enum LineChanges {
    /// Lines added and removed in these files compared with the last commit;
    /// new untracked files count as all added. Nil outside git.
    public static func count(cwd: String, files: [String]) -> (added: Int, removed: Int)? {
        guard !files.isEmpty, let repo = SafetyNet.git(cwd, ["rev-parse", "--show-toplevel"]) else { return nil }
        var added = 0, removed = 0
        let numstat = SafetyNet.git(repo, ["diff", "--numstat", "HEAD", "--"] + files) ?? ""
        var counted = Set<String>()
        for line in numstat.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            added += Int(parts[0]) ?? 0
            removed += Int(parts[1]) ?? 0
            counted.insert((repo as NSString).appendingPathComponent(parts[2]))
        }
        let untracked = SafetyNet.git(repo, ["ls-files", "--others", "--exclude-standard", "--full-name", "--"] + files) ?? ""
        for name in untracked.split(separator: "\n").map(String.init) {
            let path = (repo as NSString).appendingPathComponent(name)
            guard !counted.contains(path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  ((attributes[.size] as? NSNumber)?.intValue ?? 0) < 2 << 20,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            added += text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
        }
        return (added, removed)
    }
}
