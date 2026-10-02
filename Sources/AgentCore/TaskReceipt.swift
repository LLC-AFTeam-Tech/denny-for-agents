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
