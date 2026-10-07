import AgentCore
import Foundation

/// Runs Office tasks: on this Mac each in its own git branch and working copy,
/// headless, under the careful policy; on a server through its worker. Also the
/// manager's side: second-opinion review, budgets, the stand-up and recurring
/// tasks. Main thread.
final class OfficeRunner {
    private(set) var tasks: [OfficeTask]
    private(set) var settings = OfficeSettings.load() {
        didSet { settings.save() }
    }
    /// For the board; main thread.
    var onChange: () -> Void = {}
    /// A task is ready for review (or failed, or merged): for Telegram.
    var onReport: (OfficeTask) -> Void = { _ in }
    /// Accepting failed (a conflict, say): for the board and Telegram.
    var onAcceptFailed: (OfficeTask, String) -> Void = { _, _ in }
    /// Time for the morning stand-up.
    var onStandup: (Office.Standup) -> Void = { _ in }
    /// Hands a job to a server's worker.
    var sendRemote: (RemoteJob, String) -> Void = { _, _ in }
    /// The live plan limits, for "let Denny decide".
    var limits: () -> [AgentKind: UsageReport.Limits] = { [:] }

    private var processes: [String: Process] = [:]
    private var budgetChecked = Date.distantPast
    /// Tasks being stopped for their budget.
    private var overBudget: Set<String> = []
    private let binary: (AgentKind) -> String?

    init(binary: @escaping (AgentKind) -> String?) {
        self.binary = binary
        tasks = Office.interrupted(Office.load(), reason: L.officeInterrupted)
        Office.save(tasks)
    }

    var isWorking: Bool { !processes.isEmpty || tasks.contains { $0.host == nil && $0.column == .working } }

    func task(_ id: String) -> OfficeTask? { tasks.first { $0.id == id } }

    func task(forSession sessionId: String) -> OfficeTask? { tasks.first { $0.sessionId == sessionId } }

    func contains(_ id: String) -> Bool { tasks.contains { $0.id == id } }

    func updateSettings(_ change: (inout OfficeSettings) -> Void) {
        change(&settings)
        onChange()
    }

    // MARK: - Giving tasks

    /// `agent` nil: Denny picks by the plan limits.
    @discardableResult
    func add(prompt: String, agent: AgentKind?, folder: String, host: String? = nil, fromPhone: Bool = false) -> OfficeTask? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = folder.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !place.isEmpty else { return nil }
        let who = agent ?? Office.pickAgent(limits: limits(),
                                            available: host == nil ? AgentKind.allCases.filter { binary($0) != nil } : AgentKind.allCases)
        var task = OfficeTask(prompt: text, agent: who, folder: place, host: host)
        if fromPhone { task.fromPhone = true }
        tasks.append(task)
        changed()
        if let host { sendRemote(Office.remoteStart(task, settings: settings), host) }
        tick()
        return task
    }

    /// The agent finished a turn: its last words and what it cost.
    func noteTurn(task id: String, summary: String?, tokens: Int, cost: Double?) {
        update(id) { task in
            var report = task.report ?? OfficeReport()
            if let summary, !summary.isEmpty { report.summary = String(summary.prefix(4000)) }
            report.addUsage(tokens: tokens, cost: cost)
            task.report = report
        }
    }

    /// The agent's session, for "Rework" later.
    func noteSession(task id: String, sessionId: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].sessionId != sessionId else { return }
        tasks[index].sessionId = sessionId
        changed()
    }

    // MARK: - Decisions

    /// "Rework": the same agent goes on in the same working copy.
    func rework(id: String, remarks: String) {
        let text = remarks.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let task = self.task(id), task.column == .review, processes[id] == nil else { return }
        if let host = task.host {
            update(id) { $0.state = .queued }
            sendRemote(Office.remoteRework(task, remarks: text, settings: settings), host)
            return
        }
        update(id) { $0.state = .working(since: Date()) }
        if let ready = self.task(id) {
            launch(ready, arguments: Office.reworkArguments(ready, remarks: text, settings: settings))
        }
    }

    /// A queued task is dropped, a running one stopped (its work kept for review).
    func stop(id: String) {
        guard let task = self.task(id) else { return }
        if let host = task.host {
            if task.column == .inbox || task.column == .working {
                sendRemote(RemoteJob(kind: .cancel, target: id), host)
            }
            if task.state == .queued {
                tasks.removeAll { $0.id == id }
                changed()
            }
            return
        }
        switch task.state {
        case .queued:
            tasks.removeAll { $0.id == id }
            changed()
        case .working:
            processes[id]?.terminate()
        default:
            break
        }
    }

    /// Merges the work into the project. `done(nil)` on success (or once sent
    /// to the server), else why not.
    func accept(id: String, done: @escaping (String?) -> Void = { _ in }) {
        guard let task = self.task(id), task.column == .review else { return done(nil) }
        if let host = task.host {
            sendRemote(Office.remoteDecision(task, accept: true), host)
            return done(nil)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let error = OfficeWorkspace.accept(task)
            DispatchQueue.main.async {
                if let error {
                    self.onAcceptFailed(task, error)
                } else {
                    self.update(id) { $0.state = .accepted(at: Date()) }
                    if let accepted = self.task(id) { self.onReport(accepted) }
                }
                done(error)
            }
        }
    }

    /// Throws the work away.
    func discard(id: String) {
        guard let task = self.task(id), task.column == .review else { return }
        if let host = task.host {
            sendRemote(Office.remoteDecision(task, accept: false), host)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            OfficeWorkspace.discard(task)
            DispatchQueue.main.async { self.update(id) { $0.state = .discarded(at: Date()) } }
        }
    }

    /// Clears a finished card off the board.
    func forget(id: String) {
        tasks.removeAll { $0.id == id && $0.column == .done }
        changed()
    }

    /// What a server's worker reports about its task.
    func apply(_ result: RemoteJobResult) {
        guard let id = result.task, let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard Office.apply(result, to: &tasks[index]) else { return }
        changed()
        let task = tasks[index]
        switch result.state {
        case "review", "failed", "accepted": onReport(task)
        case "acceptFailed": onAcceptFailed(task, result.output ?? "—")
        default: break
        }
    }

    // MARK: - Manager

    /// Every few seconds: start what may start, watch budgets, recurring tasks, the stand-up.
    func tick() {
        for task in Office.startable(tasks) { start(task) }
        checkCodexBudgets()
        for index in settings.recurring.indices where settings.recurring[index].isDue() {
            let item = settings.recurring[index]
            settings.recurring[index].lastRun = Date()
            add(prompt: item.prompt, agent: item.agent, folder: item.folder, host: item.host)
        }
        if Office.standupDue(settings) {
            let since = settings.lastStandup ?? Date().addingTimeInterval(-86400)
            settings.lastStandup = Date()
            let standup = Office.standup(tasks, since: since)
            if !standup.isEmpty { onStandup(standup) }
        }
    }

    func addRecurring(_ item: OfficeRecurring) {
        settings.recurring.append(item)
        onChange()
    }

    func removeRecurring(id: String) {
        settings.recurring.removeAll { $0.id == id }
        onChange()
    }

    // MARK: - Running on this Mac

    private func start(_ task: OfficeTask) {
        update(task.id) { $0.state = .working(since: Date()) }
        DispatchQueue.global(qos: .userInitiated).async {
            let prepared = OfficeWorkspace.prepare(task)
            DispatchQueue.main.async {
                if let error = prepared.error {
                    self.finish(task.id, state: .failed(at: Date(), reason: error))
                    if let failed = self.task(task.id) { self.onReport(failed) }
                    return
                }
                self.update(task.id) {
                    $0.branch = prepared.task.branch
                    $0.base = prepared.task.base
                    $0.workdir = prepared.task.workdir
                }
                if let ready = self.task(task.id) { self.launch(ready, arguments: Office.arguments(ready, settings: self.settings)) }
            }
        }
    }

    private func launch(_ task: OfficeTask, arguments: [String]) {
        guard let binary = binary(task.agent), FileManager.default.fileExists(atPath: task.runFolder) else {
            finish(task.id, state: .failed(at: Date(), reason: L.reviewNotFound))
            if let failed = self.task(task.id) { onReport(failed) }
            return
        }
        let review = settings.review
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "\"$0\" \"$@\"", binary] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: task.runFolder)
        process.environment = ProcessInfo.processInfo.environment.merging([NightShift.environmentKey: task.id]) { _, new in new }
        // The agent's output goes to a log: a failed task then says why, not just "exit 1".
        let log = Office.logFile(for: task)
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: log)
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            try? logHandle?.close()
            let ok = finished.terminationReason == .exit && finished.terminationStatus == 0
            let stopped = finished.terminationReason == .uncaughtSignal
            // Whatever the agent left, committed on its branch; then what
            // changed, the tests and (if asked) the other agent's review.
            OfficeWorkspace.commitLeftovers(task)
            let numstat = OfficeWorkspace.changes(task)
            let tests = ok ? Self.runTests(task.runFolder) : nil
            let second = ok && review ? self?.secondOpinion(task) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.processes[task.id] = nil
                let overBudget = self.overBudget.remove(task.id) != nil
                self.update(task.id) { current in
                    var report = current.report ?? OfficeReport()
                    if let numstat { report.setChanges(numstat: numstat) }
                    report.tests = tests?.passed.map { $0 ? "passed" : "failed" }
                    report.testOutput = tests?.output
                    if let second {
                        report.reviewer = second.reviewer
                        report.review = second.text
                        report.findings = second.text.map(CrossReview.findings(in:))
                    }
                    current.report = report
                }
                let reason = overBudget ? L.officeOverBudget : stopped ? L.officeStopped
                    : Office.failureReason(log: try? String(contentsOf: log, encoding: .utf8), status: finished.terminationStatus)
                self.finish(task.id, state: ok ? .review(at: Date()) : .failed(at: Date(), reason: reason))
                if let done = self.task(task.id) { self.onReport(done) }
            }
        }
        guard (try? process.run()) != nil else {
            finish(task.id, state: .failed(at: Date(), reason: "—"))
            return
        }
        processes[task.id] = process
        DispatchQueue.main.asyncAfter(deadline: .now() + NightShift.timeout) { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
    }

    /// Codex has no prices: its running tasks are stopped at the token budget.
    private func checkCodexBudgets() {
        guard let limit = settings.codexBudgetK.map({ $0 * 1000 }), limit > 0,
              Date().timeIntervalSince(budgetChecked) > 30 else { return }
        budgetChecked = Date()
        let running = tasks.filter { $0.host == nil && $0.agent == .codex && $0.column == .working && $0.sessionId != nil }
        for task in running {
            guard let session = task.sessionId, let process = processes[task.id] else { continue }
            DispatchQueue.global(qos: .utility).async {
                let payload = (try? JSONSerialization.data(withJSONObject: ["session_id": session])) ?? Data()
                guard let rollout = TurnUsage.codexRollout(payload: payload) else { return }
                let used = Office.budgetTokens(TurnUsage.codex(rollout: rollout))
                guard used > limit else { return }
                DispatchQueue.main.async {
                    guard process.isRunning else { return }
                    self.overBudget.insert(task.id)
                    process.terminate()
                }
            }
        }
    }

    /// Blocking. The other agent reads the task's change, read-only.
    private func secondOpinion(_ task: OfficeTask) -> (reviewer: AgentKind, text: String?)? {
        let reviewer = CrossReview.reviewer(for: task.agent)
        guard let path = binary(reviewer), let base = task.base,
              let root = OfficeWorkspace.git(Office.Git.repoRoot(task.runFolder)).text.nilIfEmpty else { return nil }
        let diff = OfficeWorkspace.git(["-C", root, "diff", base + "...HEAD"]).text
        guard !diff.isEmpty else { return nil }
        let prompt = CrossReview.prompt(author: task.agent, task: task.prompt, diff: String(diff.prefix(CrossReview.maxDiff)))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "\"$0\" \"$@\"", path] + CrossReview.arguments(reviewer: reviewer, prompt: prompt)
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (reviewer, nil) }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + CrossReview.timeout, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (reviewer, process.terminationStatus == 0 && !text.isEmpty ? String(text.prefix(6000)) : nil)
    }

    /// Blocking. passed nil: no tests in this project (or none runnable in a fresh copy).
    private static func runTests(_ folder: String) -> (passed: Bool?, output: String?) {
        guard let found = Office.testCommand(runFolder: folder) else { return (nil, nil) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", found.command]
        process.currentDirectoryURL = URL(fileURLWithPath: found.root)
        process.environment = ProcessInfo.processInfo.environment.merging(["CI": "1"]) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (nil, nil) }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + TestRunner.timeout, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        let text = TestRunner.tail(String(decoding: data, as: UTF8.self), lines: 30)
        return (process.terminationReason == .exit && process.terminationStatus == 0, found.command + "\n" + text)
    }

    private func finish(_ id: String, state: OfficeTask.State) {
        update(id) { $0.state = state }
        tick()
    }

    private func update(_ id: String, _ change: (inout OfficeTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[index])
        changed()
    }

    private func changed() {
        Office.save(tasks)
        onChange()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
