import AgentCore
import Foundation

/// The Office in Telegram: reports with Accept / Throw away, replies to rework,
/// /task and /board. Main thread.
extension AgentsController {
    private var phone: TelegramBridge { .shared }

    /// "Who and where?" choices waiting for a tap: key -> the task text and the places.
    private static var picks: [String: (prompt: String, places: [(folder: String, host: String?)])] = [:]

    func reportOffice(_ task: OfficeTask) {
        guard phone.isConnected, task.fromPhone == true || phone.shouldForward else { return }
        switch task.state {
        case .review:
            phone.sendOfficeReport(OfficeTexts.report(task), task: task.id, buttons: true)
        case .failed:
            // Partial work on a branch can still be looked at, kept or thrown away.
            phone.sendOfficeReport(OfficeTexts.report(task), task: task.id, buttons: task.branch != nil || task.host != nil)
        default:
            break
        }
    }

    func officeAcceptFailed(_ task: OfficeTask, error: String) {
        guard phone.isConnected, task.fromPhone == true || phone.shouldForward else { return }
        phone.send("⚠️ " + task.title + "\n" + L.officeAcceptFailed(String(error.prefix(500))), force: true)
    }

    func officeAction(_ action: String, payload: String, message: Int64) {
        switch action {
        case "oa":
            guard let task = office.task(payload), task.column == .review else { return phone.answer(message, text: L.officeTgExpired) }
            phone.clearButtons(message)
            office.accept(id: payload) { [weak self] error in
                guard error == nil else { return }  // officeAcceptFailed tells why
                if task.host == nil { self?.phone.answer(message, text: L.officeTgAccepted(task.base ?? "—")) }
            }
        case "ox":
            guard let task = office.task(payload), task.column == .review else { return phone.answer(message, text: L.officeTgExpired) }
            phone.clearButtons(message)
            office.discard(id: payload)
            phone.answer(message, text: L.officeTgDiscarded)
        case "ot":
            // key:placeIndex:agent (a = Denny decides, c = Claude, x = Codex)
            let parts = payload.split(separator: ":").map(String.init)
            guard parts.count == 3, let pick = Self.picks.removeValue(forKey: parts[0]),
                  let index = Int(parts[1]), pick.places.indices.contains(index) else {
                return phone.answer(message, text: L.officeTgExpired)
            }
            phone.clearButtons(message)
            let agent: AgentKind? = parts[2] == "c" ? .claude : parts[2] == "x" ? .codex : nil
            let place = pick.places[index]
            guard let task = office.add(prompt: pick.prompt, agent: agent, folder: place.folder, host: place.host, fromPhone: true) else { return }
            phone.answer(message, text: L.officeTgGiven(task.agent.displayName, OfficeTexts.place(task)))
        default:
            break
        }
    }

    func officeRework(_ id: String, text: String, message: Int64) {
        guard let task = office.task(id), task.column == .review else { return phone.answer(message, text: L.officeTgExpired) }
        office.rework(id: id, remarks: text)
        phone.answer(message, text: L.officeTgReworking(task.agent.displayName))
    }

    func telegramCommand(_ command: String, text: String, message: Int64) {
        switch command {
        case "task":
            let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return phone.answer(message, text: L.officeTgHow) }
            let places = officePlaces()
            guard !places.isEmpty else { return phone.answer(message, text: L.officeTgNoFolders) }
            let key = String(UUID().uuidString.prefix(6))
            Self.picks[key] = (prompt: prompt, places: places)
            if Self.picks.count > 20, let oldest = Self.picks.keys.first(where: { $0 != key }) { Self.picks[oldest] = nil }
            let rows: [[(String, String)]] = places.enumerated().map { index, place in
                let name = (place.folder as NSString).lastPathComponent + (place.host.map { " @" + $0 } ?? "")
                return [("📁 " + name + " · " + L.officeAuto, "ot:\(key):\(index):a"),
                        ("Claude", "ot:\(key):\(index):c"),
                        ("Codex", "ot:\(key):\(index):x")]
            }
            phone.sendChoices(L.officeTgPick, rows: rows, replyTo: message)
        case "board":
            phone.answer(message, text: OfficeTexts.board(office.tasks))
        default:
            phone.answer(message, text: L.officeTgHow)
        }
    }

    /// Projects for "which one?": the newest Office folders and agent folders on
    /// this Mac, then each server's latest.
    private func officePlaces() -> [(folder: String, host: String?)] {
        let local = office.tasks.filter { $0.host == nil }.sorted { $0.createdAt > $1.createdAt }.map(\.folder)
            + [recentFolder(host: nil)].compactMap { $0 }
        var places: [(folder: String, host: String?)] = Office.recentFolders(local.filter {
            FileManager.default.fileExists(atPath: $0)
        }, limit: 3).map { (folder: $0, host: nil) }
        for host in knownHosts.prefix(2) {
            let folder = office.tasks.filter { $0.host == host }.sorted { $0.createdAt > $1.createdAt }.first?.folder
                ?? recentFolder(host: host)
            if let folder, !Office.recentFolders([folder]).isEmpty { places.append((folder: folder, host: host)) }
        }
        return Array(places.prefix(4))
    }
}

/// The Office's words for Telegram.
enum OfficeTexts {
    static func place(_ task: OfficeTask) -> String {
        (task.folder as NSString).lastPathComponent + (task.host.map { " @" + $0 } ?? "")
    }

    static func report(_ task: OfficeTask) -> String {
        var lines: [String] = []
        if case .failed(_, let reason) = task.state {
            lines.append("⚠️ " + task.agent.displayName + " · " + place(task) + ": " + task.title)
            lines.append(L.nightFailedShort(String(reason.prefix(300))))
        } else {
            lines.append("📋 " + task.agent.displayName + " · " + place(task) + ": " + task.title)
        }
        if let summary = task.report?.summary, !summary.isEmpty {
            lines.append("")
            lines.append(summary.count > 1200 ? String(summary.prefix(1199)) + "…" : summary)
        }
        if let stats = stats(task) {
            lines.append("")
            lines.append(stats)
        }
        if let review = task.report?.review, let reviewer = task.report?.reviewer {
            let findings = task.report?.findings ?? 0
            lines.append(findings == 0 ? L.officeReviewClean(reviewer.displayName) : L.officeReviewFindings(reviewer.displayName, findings))
            if findings > 0 { lines.append(review.count > 800 ? String(review.prefix(799)) + "…" : review) }
        }
        lines.append("")
        lines.append(L.officeTgReplyHint)
        return lines.joined(separator: "\n")
    }

    /// "3 files · +40 −5 · tests ✅ · $0.42"
    static func stats(_ task: OfficeTask) -> String? {
        guard let report = task.report else { return nil }
        var parts: [String] = []
        if !report.files.isEmpty { parts.append(L.officeChanges(report.files.count, report.added, report.removed)) }
        if let tests = report.tests { parts.append(tests == "passed" ? L.officeTestsPassed : L.officeTestsFailed) }
        if let cost = report.cost, cost > 0 {
            parts.append(Fmt.cost(cost))
        } else if report.tokens > 0 {
            parts.append(L.tokens(Fmt.tokens(report.tokens)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func board(_ tasks: [OfficeTask]) -> String {
        guard !tasks.filter({ $0.column != .done }).isEmpty else { return L.officeTgBoardEmpty }
        var lines: [String] = []
        for column in [OfficeTask.Column.review, .working, .inbox] {
            let cards = tasks.filter { $0.column == column }
            guard !cards.isEmpty else { continue }
            lines.append(L.officeColumn(column) + " · \(cards.count)")
            lines += cards.prefix(8).map { "• " + $0.agent.shortName + " · " + place($0) + ": " + $0.title }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func standup(_ standup: Office.Standup) -> String {
        var lines = [L.officeStandupTitle]
        if !standup.finished.isEmpty {
            lines.append(L.officeStandupDone(standup.finished.count))
            lines += standup.finished.prefix(6).map { "• " + $0.title }
        }
        if !standup.waiting.isEmpty {
            lines.append(L.officeStandupWaiting(standup.waiting.count))
            lines += standup.waiting.prefix(6).map { "• " + $0.title }
        }
        if !standup.working.isEmpty { lines.append(L.officeStandupWorking(standup.working.count)) }
        if standup.queued > 0 { lines.append(L.officeStandupQueued(standup.queued)) }
        if standup.cost > 0 {
            lines.append(L.officeStandupSpent(Fmt.cost(standup.cost)))
        } else if standup.tokens > 0 {
            lines.append(L.officeStandupSpent(L.tokens(Fmt.tokens(standup.tokens))))
        }
        return lines.joined(separator: "\n")
    }
}
