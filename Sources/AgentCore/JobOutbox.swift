import Foundation

/// Jobs for servers' workers, kept until each server says it has stored them,
/// and saved with the app so a restart loses nothing (cancels included).
/// A reply lost on a dropped connection just means the job is sent again; the
/// worker recognises it by id. Results a worker resends because *our* reply
/// got lost are recognised here and applied once.
public struct JobOutbox: Codable, Equatable, Sendable {
    /// Host -> jobs not acknowledged yet, oldest first.
    public var waiting: [String: [RemoteJob]] = [:]
    /// Job id -> the receipt it belongs to.
    public var receipts: [String: String] = [:]
    /// "id|state" of results already applied, newest last.
    public var applied: [String] = []
    public static let appliedKeep = 500

    public init() {}

    public mutating func add(_ job: RemoteJob, host: String) {
        waiting[host, default: []].append(job)
    }

    /// The results not applied before, in order; remembers them.
    public mutating func fresh(_ results: [RemoteJobResult]) -> [RemoteJobResult] {
        var new: [RemoteJobResult] = []
        for result in results {
            let key = result.id + "|" + result.state
            guard !applied.contains(key) else { continue }
            applied.append(key)
            new.append(result)
        }
        if applied.count > Self.appliedKeep { applied.removeFirst(applied.count - Self.appliedKeep) }
        return new
    }

    /// What to hand a worker that has stored `received` (ids). An older hook
    /// sends nil and acknowledges nothing: hand over and forget, as before.
    public mutating func deliver(host: String, received: [String]?) -> [RemoteJob] {
        guard let received else { return waiting.removeValue(forKey: host) ?? [] }
        let stored = Set(received)
        if let jobs = waiting[host], jobs.contains(where: { stored.contains($0.id) }) {
            let rest = jobs.filter { !stored.contains($0.id) }
            waiting[host] = rest.isEmpty ? nil : rest
        }
        return waiting[host] ?? []
    }

    public static func load(from url: URL) -> JobOutbox {
        guard let data = try? Data(contentsOf: url),
              let outbox = try? JSONDecoder().decode(JobOutbox.self, from: data) else { return JobOutbox() }
        return outbox
    }

    public func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
    }
}
