import AgentCore
import AppKit
import Combine
import SwiftUI

/// Owns the agent model, the bridge server and the notch panel.
final class AgentsController {
    static let fullDennyURL = URL(string: "https://afteam.tech/denny/?utm_source=denny-for-agents")!

    let model = AgentsViewModel()
    private var store = AgentStore()
    private let server = AgentBridgeServer()
    private let collector = UsageCollector()
    /// SSH connections Denny keeps itself (no Termius, reconnects on its own).
    private(set) lazy var ssh = SSHTunnelManager(localSetup: { [weak self] in self?.remoteSetup })
    /// Latest report per machine: this Mac and every SSH server.
    private var reports: [String: UsageReport] = [:]
    /// Last time each SSH server reached Denny, by any event or report.
    private var remoteSeen: [String: Date] = [:]
    /// Relay offers already made or dismissed, so each shows once.
    private var relaySeen: Set<String> = []
    private var panel: NotchPanel?
    private var swipeMonitor: Any?
    private let telegram = TelegramBridge.shared
    private var nightSessions: Set<String> = []
    private var nightProcess: Process?
    /// Queued and finished night-shift jobs, saved in ~/.denny-for-agents.
    private(set) var nightJobs = NightShift.load()
    private var swipe = CGVector.zero
    private var swipeDone = false
    private var timer: Timer?
    private var hovering = false
    private var collapseWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?
    private var lastPeek = Date.distantPast
    static let peekDuration: TimeInterval = 5
    /// The finish clips run 5 s; hold the last frame a moment.
    static let celebrationDuration: TimeInterval = 6
    static let peekCooldown: TimeInterval = 90
    /// Every new task gets a peek; this only stops flicker on rapid messages.
    static let taskPeekCooldown: TimeInterval = 10
    static let finishPeekCooldown: TimeInterval = 3
    private var dropMessageWork: DispatchWorkItem?
    private var outbox = FileOutbox()
    private var limitLevels: [String: Double] = [:]
    private let prices = PriceUpdater()
    private let keepAwake = KeepAwake()
    private let accessories = AccessoryButtons()
    let lidGuard = LidSleepGuard()
    var onOpenSettings: () -> Void = {}
    let settings = AppSettings.shared
    private var settingsObserver: AnyCancellable?
    let notifier = Notifier()
    private var dropObserver: AnyCancellable?

    func start() {
        // A job "running" at launch was cut off by a restart or a crash.
        // A server keeps running its own jobs, so only this Mac's are affected.
        for index in nightJobs.indices where nightJobs[index].host == nil {
            if case .running = nightJobs[index].state { nightJobs[index].state = .failed(at: Date(), reason: L.nightInterrupted) }
        }
        NightShift.save(nightJobs)
        restoreServerReports()
        telegram.onDecision = { [weak self] id, decision in self?.answer(id: id, decision: decision) }
        telegram.start()
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleSwipe(event)
        }
        server.onEvent = { [weak self] event, requestId in
            self?.handle(event, requestId: requestId)
        }
        server.onFilesRequest = { [weak self] event in
            self?.deliverFiles(for: event) ?? []
        }
        server.onJobsRequest = { [weak self] host, results, received in
            self?.jobsRequested(host: host, results: results, received: received) ?? []
        }
        server.onReport = { [weak self] report in
            self?.receive(report, from: report.host)
        }
        collector.onReport = { [weak self] report in
            self?.receive(report, from: "this-mac")
        }

        lidGuard.restoreIfNeeded()
        accessories.onHover = { [weak self] hovering in self?.handleHover(hovering) }
        collector.start()
        prices.start()
        settingsObserver = settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.applySettings() }
        }
        model.serverRunning = server.start()
        ssh.onReport = { [weak self] report in
            self?.receive(report, from: report.host)
        }
        ssh.start()
        refreshHooksState()
        setUpPanel()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.layout(animated: false)
        }
        react(.joy)
        render()
    }

    /// Hosts that sent a report, for the settings window.
    var serverLoads: [(host: String, system: UsageReport.System, at: Date)] {
        reports.filter { $0.key != "this-mac" }
            .compactMap { _, report in report.system.map { (report.host, $0, Date(timeIntervalSince1970: report.generatedAt)) } }
            .sorted { $0.host < $1.host }
    }

    var remoteHosts: [(name: String, lastSeen: Date)] {
        remoteSeen.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    private func updateAccessories(island: CGRect) {
        guard model.mode == .expanded else {
            accessories.hide()
            return
        }
        var left: [AccessoryButtons.Item] = []
        if StatsPage.hasContent(model.summary, visible: model.visibleCards) {
            left = [
                .init(symbol: "square.grid.2x2", title: L.pageOverview, selected: model.page == .overview) { [weak self] in
                    self?.show(page: .overview)
                },
                .init(symbol: "chart.bar.xaxis", title: L.pageStats, selected: model.page == .stats) { [weak self] in
                    self?.show(page: .stats)
                }
            ]
        }
        let quietTitle = settings.isQuiet ? L.quietActive(Fmt.time(settings.quietUntil ?? Date())) : L.quietOn
        let right: [AccessoryButtons.Item] = [
            .init(symbol: settings.isQuiet ? "bell.slash.fill" : "bell.slash", title: quietTitle, selected: settings.isQuiet) { [weak self] in
                self?.toggleQuiet()
            },
            .init(symbol: "arrow.clockwise", title: L.refreshNow, selected: false) { [weak self] in self?.refreshNow() },
            .init(symbol: "gearshape", title: L.settingsTitle, selected: false) { [weak self] in self?.onOpenSettings() }
        ]
        accessories.show(around: island, topInset: model.notchHeight, left: left, right: right)
    }

    /// Awake while a local agent works (servers don't sleep) or while the
    /// manual timer runs; lid-closed only on the charger, off otherwise.
    func updateAwake() {
        if settings.awakeUntil != nil, !settings.manualAwakeActive { settings.awakeUntil = nil }
        let localWork = store.sessions.values.contains {
            $0.host == nil && ($0.status == .working || $0.status == .waitingApproval)
        }
        let nightWork = nightProcess != nil
        let hold = (settings.keepAwake && localWork) || settings.manualAwakeActive || nightWork
        keepAwake.update(shouldHold: hold)
        lidGuard.set(hold && settings.keepAwakeLidClosed && LidSleepGuard.onACPower)
    }

    private func applySettings() {
        model.visibleCards = settings.visibleCards
        model.readout = settings.readout
        if var behavior = panel?.collectionBehavior {
            if settings.showInFullScreen { behavior.insert(.fullScreenAuxiliary) } else { behavior.remove(.fullScreenAuxiliary) }
            panel?.collectionBehavior = behavior
        }
        layout(animated: false)
        render()
    }

    func stop() {
        // ssh children would outlive the app and keep the old tunnels.
        ssh.stopAll()
        accessories.hide()
        keepAwake.update(shouldHold: false)
        lidGuard.set(false)
        timer?.invalidate()
        server.stop()
    }

    var remoteSetup: (port: UInt16, token: String)? {
        guard server.remoteListening, let token = server.remoteToken else { return nil }
        return (server.remotePort, token)
    }

    func refreshHooksState() {
        model.hooksInstalled = HookSetup.anyInstalled
    }

    // MARK: - Events

    private func handle(_ event: HookEvent, requestId: String?) {
        if let host = event.host { remoteSeen[host] = Date() }
        if event.nightShift != nil { nightSessions.insert(AgentStore.key(agent: event.agent, sessionId: event.sessionId)) }
        let effects = store.apply(event, requestId: requestId)
        for effect in effects {
            switch effect {
            case .celebrate(let key, let duration):
                react(.joy)
                collector.refresh()
                if settings.peekOnFinish, let session = store.sessions[key] {
                    let detail = duration.map { L.finishedBody(session.projectName, Fmt.countdown($0)) } ?? session.projectName
                    let title = L.finishedTitle(session.agent)
                    if DennyClipView.url(DennyClipView.finishFile(session.agent)) != nil {
                        // A quick answer can finish while the start-of-task peek is still up.
                        peek(.celebration(agent: session.agent, title: title, detail: detail),
                             cooldown: 0, duration: Self.celebrationDuration)
                    } else {
                        peek(.finished(title: title, detail: detail), cooldown: Self.finishPeekCooldown)
                    }
                }
                if telegram.settings.sendFinished, let session = store.sessions[key] {
                    telegram.send("✅ " + L.finishedTitle(session.agent) + " · "
                                  + (duration.map { L.finishedBody(session.projectName, Fmt.countdown($0)) } ?? session.projectName))
                }
                if !settings.isQuiet, notifier.settings.notifiesFinish(after: duration), let session = store.sessions[key] {
                    notifier.post(title: L.finishedTitle(session.agent),
                                  body: L.finishedBody(session.projectName, duration.map(Fmt.countdown) ?? "—"))
                }
            case .startedStep(_, let kind):
                if settings.peekOnWriting { peek(.activity(kind == .writing ? .notes : .tasks)) }
            case .looksStuck(let key, let reason):
                guard settings.stuckAlerts, !settings.isQuiet, let session = store.sessions[key] else { break }
                react(.think)
                let title = L.stuckTitle(session.agent)
                peek(.finished(title: title, detail: L.stuckReason(reason)), cooldown: Self.finishPeekCooldown)
                notifier.post(title: title, body: session.projectName + " · " + L.stuckReason(reason))
            case .turnStarted:
                if settings.peekOnStart { peek(.activity(.notes), cooldown: Self.taskPeekCooldown) }
                // Racing a limit: Denny buckles down at the start of each task.
                if let limit = model.restingLimit, limit.window.percent >= 80 {
                    react(.think)
                }
            case .receipt(let receipt):
                model.receipt = receipt
                model.receiptTestCommand = nil
                model.reviewer = nil
                if let host = receipt.host, let cwd = receipt.cwd, !receipt.files.isEmpty {
                    // The server's worker runs these there; it answers when it can.
                    model.receiptTestCommand = L.testsOnServer(host)
                    model.reviewer = CrossReview.reviewer(for: receipt.agent)
                    let lines = RemoteJob(kind: .lines, cwd: cwd, files: receipt.files)
                    remoteJobReceipts[lines.id] = receipt.id
                    queue(lines, host: host, quietly: true)
                    if settings.autoRunTests { runTests(for: receipt) }
                }
                if receipt.host == nil, let cwd = receipt.cwd, !receipt.files.isEmpty {
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        let found = TestRunner.detect(cwd: cwd)
                        let reviewer = CrossReview.reviewer(for: receipt.agent)
                        let canReview = Self.binary(for: reviewer) != nil
                            && CrossReview.diff(cwd: cwd, files: receipt.files) != nil
                        DispatchQueue.main.async {
                            guard let self, self.model.receipt?.id == receipt.id else { return }
                            self.model.reviewer = canReview ? reviewer : nil
                            if let found {
                                self.model.receiptTestCommand = found.command
                                if self.settings.autoRunTests { self.runTests(for: receipt) }
                            }
                            self.render()
                        }
                    }
                }
                if receipt.host == nil, let cwd = receipt.cwd, !receipt.files.isEmpty {
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        let changes = LineChanges.count(cwd: cwd, files: receipt.files)
                        DispatchQueue.main.async {
                            guard let self, let changes, self.model.receipt?.id == receipt.id else { return }
                            self.model.receipt?.added = changes.added
                            self.model.receipt?.removed = changes.removed
                            self.render()
                        }
                    }
                }
            case .snapshotTaken(let key, let snapshot):
                let notice = SafetyNetNotice(snapshot: snapshot, host: store.sessions[key]?.host)
                model.safetyNet = notice
                if notice.host != nil {
                    remoteSnapshots.append(notice)
                    if remoteSnapshots.count > SafetyNet.keep { remoteSnapshots.removeFirst() }
                }
                peek(.finished(title: L.safetyPeekTitle, detail: snapshot.command))
            case .needsAttention(let id):
                // A night-shift session asked anyway: answer with the careful policy.
                if let approval = store.approvals.first(where: { $0.id == id }), nightSessions.contains(approval.sessionKey) {
                    answer(id: id, decision: NightShift.decision(for: approval.risk))
                    continue
                }
                if let approval = store.approvals.first(where: { $0.id == id }) {
                    telegram.sendApproval(id: id, text: L.phoneRequestText(approval))
                }
                // Denny reacts to what is being asked: calm, wary or scared.
                switch store.approvals.first(where: { $0.id == id })?.risk.level ?? .safe {
                case .safe, .caution:
                    react(.idea)
                    NSSound(named: "Tink")?.play()
                case .danger:
                    react(.scared)
                    NSSound(named: "Funk")?.play()
                case .critical:
                    react(.scared)
                    NSSound(named: "Basso")?.play()
                }
            }
        }
        render()
    }

    private static var savedReportsURL: URL { BridgePaths.directory().appendingPathComponent("server-reports.json") }

    /// Servers' last reports from before a restart: the notch shows them (as
    /// "updated N min ago") until a fresh one comes in.
    private func restoreServerReports() {
        guard let data = try? Data(contentsOf: Self.savedReportsURL),
              let saved = try? JSONDecoder().decode([String: UsageReport].self, from: data) else { return }
        for (source, report) in saved where reports[source] == nil {
            reports[source] = report
            remoteSeen[report.host] = Date(timeIntervalSince1970: report.generatedAt)
        }
        model.summary = UsageSummary.combine(Array(reports.values))
    }

    private func saveServerReports() {
        let remote = reports.filter { $0.key != "this-mac" }
        guard let data = try? JSONEncoder().encode(remote) else { return }
        try? data.write(to: Self.savedReportsURL, options: .atomic)
    }

    private func receive(_ report: UsageReport, from source: String) {
        // The same server arrives by the port and over SSH: keep the newer.
        if let current = reports[source], current.generatedAt > report.generatedAt { return }
        reports[source] = report
        if source != "this-mac" {
            // When the server made it, not when it got here: an old report
            // must read as "no contact for N min", not as live.
            let made = min(Date(), Date(timeIntervalSince1970: report.generatedAt))
            remoteSeen[report.host] = max(remoteSeen[report.host] ?? .distantPast, made)
            saveServerReports()
        }
        if source == "this-mac" {
            // Only a Mac whose own Codex answered can spend a reset from here.
            model.canResetCodex = !(report.resets ?? []).isEmpty
        }
        model.summary = UsageSummary.combine(Array(reports.values))
        checkUsageAlerts()
        checkRelay()
        render()
    }

    private func answer(id: String, decision: ApprovalDecision) {
        store.resolveApproval(id: id)
        server.answer(id: id, decision: decision)
        telegram.finish(id: id, text: decision == .allow ? L.phoneAllowed : decision == .deny ? L.phoneDenied : L.phoneExpired)
        switch decision {
        case .allow: react(.joy)
        case .deny: react(.scared)
        case .ask: break
        }
        render()
    }

    private func tick() {
        // The hook stops waiting after approvalWaitSeconds and hands the
        // question back to the terminal; drop the card at the same time.
        let deadline = Date().addingTimeInterval(-TimeInterval(HookInstaller.approvalWaitSeconds))
        for approval in store.approvals where approval.receivedAt < deadline {
            store.resolveApproval(id: approval.id)
            server.answer(id: approval.id, decision: .ask)
            telegram.finish(id: approval.id, text: L.phoneExpired)
        }
        store.prune()
        refreshHooksState()
        if settings.quietUntil != nil, !settings.isQuiet { settings.quietUntil = nil }
        startDueNightJob()
        updateAwake()
        model.summary = UsageSummary.combine(Array(reports.values))
        render()
    }

    // MARK: - Rendering

    private func render() {
        model.update(from: store)
        updateAwake()
        let next = desiredMode()
        if next != model.mode {
            model.mode = next
        }
        layout(animated: true)
    }

    private func handleDrop(_ urls: [URL]) {
        let target = store.orderedSessions.first { $0.status != .finished } ?? store.orderedSessions.first
        if let host = target?.host, let home = target?.home {
            sendToServer(urls, host: host, home: home)
        } else {
            let paths = urls.map(\.path)
            copyToPasteboard(ShellQuote.join(paths))
            showDropMessage(DropMessage(
                title: L.copiedPaths(paths.count, urls.first?.lastPathComponent ?? ""),
                warning: target?.host.map(L.remoteCantSee)
            ))
        }
        react(.idea)
    }

    /// Queues the files for that server and copies the paths they will have
    /// there; the server's hook picks them up with the next message.
    private func sendToServer(_ urls: [URL], host: String, home: String) {
        let dir = FileOutbox.folder(for: Date())
        var items: [FileOutbox.Item] = []
        var total = 0
        var warnings: [String] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                if !warnings.contains(L.skippedFolders) { warnings.append(L.skippedFolders) }
                continue
            }
            guard let data = try? Data(contentsOf: url), total + data.count <= FileOutbox.maxBytes else {
                if !warnings.contains(L.tooBig) { warnings.append(L.tooBig) }
                continue
            }
            total += data.count
            items.append(FileOutbox.Item(dir: dir, name: url.lastPathComponent, data: data, createdAt: Date()))
        }
        if !items.isEmpty {
            outbox.add(items, host: host)
            copyToPasteboard(ShellQuote.join(items.map { FileOutbox.remotePath(home: home, dir: $0.dir, name: $0.name) }))
        }
        showDropMessage(DropMessage(
            title: items.isEmpty ? L.tooBig : L.willSend(items.count, host),
            warning: warnings.isEmpty ? nil : warnings.joined(separator: " ")
        ))
    }

    private func deliverFiles(for event: HookEvent) -> [FileOutbox.Item] {
        guard let host = event.host else { return [] }
        let items = outbox.take(host: host)
        if !items.isEmpty {
            showDropMessage(DropMessage(title: L.delivered(items.count, host), warning: nil))
            react(.joy)
        }
        return items
    }

    /// Offers a relay once per session and limit period when an agent runs out.
    private func checkRelay() {
        let available = Set(AgentKind.allCases.filter { model.summary.agentsSeen.contains($0) || HookInstaller.isInstalled(agent: $0) })
        guard let offer = Relay.offer(summary: model.summary, sessions: Array(store.sessions.values), available: available),
              !relaySeen.contains(offer.id) else { return }
        relaySeen.insert(offer.id)
        model.relayOffer = offer
        react(.idea)
        let until = offer.resetsAt.map { Fmt.time(Date(timeIntervalSince1970: $0)) }
        peek(.finished(title: L.relayTitle(offer.from, until: until), detail: L.relayBody(offer.to)),
             cooldown: Self.finishPeekCooldown)
    }

    private func copyRelayNote(sessionKey: String, becauseOfLimit: Bool) {
        guard let session = store.sessions[sessionKey] else { return }
        let to = Relay.other(session.agent)
        copyToPasteboard(Relay.note(for: session, to: to, becauseOfLimit: becauseOfLimit, language: L.language))
        model.relayOffer = nil
        showDropMessage(DropMessage(title: L.relayCopied(to), warning: nil))
        react(.joy)
    }

    private func checkUsageAlerts() {
        let quiet = self.settings.isQuiet
        let settings = notifier.settings
        let renewal = LimitRenewal.detect(previous: limitLevels, summary: model.summary)
        limitLevels = renewal.levels
        for limit in renewal.renewed {
            let detail = L.limitDetail(limit.window, resetsIn: nil)
            if settings.limitPercent != nil, !quiet {
                notifier.post(title: L.renewedTitle(limit.agent), body: detail)
            }
            react(.joy)
            peek(.finished(title: L.renewedTitle(limit.agent), detail: detail), cooldown: Self.finishPeekCooldown)
        }
        var tracker = notifier.tracker
        for alert in tracker.limitAlerts(model.summary, settings: settings) {
            let left = (alert.window.resetsAt ?? 0) - Date().timeIntervalSince1970
            let body = L.limitDetail(alert.window, resetsIn: left > 0 ? Fmt.countdown(left) : nil)
            if !quiet { notifier.post(title: L.limitAlertTitle(alert.agent, Int(alert.window.percent.rounded())), body: body) }
            react(.scared)
        }
        let today = model.summary.spend[.today]?.cost ?? 0
        if tracker.budgetAlert(spentToday: today, settings: settings, day: FileOutbox.folder(for: Date()).prefix(8).description) {
            if !quiet { notifier.post(title: L.budgetAlertTitle(Fmt.cost(today)), body: L.budgetAlertBody) }
        }
        notifier.tracker = tracker
    }

    private func confirmCodexReset() {
        guard !model.resettingCodex else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L.resetConfirmTitle
        alert.informativeText = L.resetConfirmBody(model.summary.resets[.codex]?.available ?? 0)
        alert.addButton(withTitle: L.useReset)
        alert.addButton(withTitle: L.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.resettingCodex = true
        collector.resetCodex { [weak self] outcome in
            guard let self else { return }
            self.model.resettingCodex = false
            self.showDropMessage(DropMessage(title: L.resetOutcome(outcome), warning: nil))
            if outcome == "reset" { self.react(.joy) }
            self.collector.refresh()
        }
    }

    /// Snapshots from servers seen since launch; local ones live in the index.
    private(set) var remoteSnapshots: [SafetyNetNotice] = []

    /// Newest first: this Mac's index plus what servers reported.
    var safetySnapshots: [SafetyNetNotice] {
        let local = SafetyNet.load().map { SafetyNetNotice(snapshot: $0, host: nil) }
        return (local + remoteSnapshots).sorted { $0.snapshot.createdAt > $1.snapshot.createdAt }
    }

    /// A server snapshot can only be restored there: copy the command.
    /// A local one is restored here after a confirmation.
    func undo(_ notice: SafetyNetNotice) {
        guard notice.host == nil else {
            copyToPasteboard(SafetyNet.restoreCommand(notice.snapshot))
            showDropMessage(DropMessage(title: L.safetyCommandCopied, warning: nil))
            return
        }
        let snapshot = notice.snapshot
        let paths = SafetyNet.preview(snapshot)
        NSApp.activate(ignoringOtherApps: true)
        guard !paths.isEmpty else {
            let alert = NSAlert()
            alert.messageText = L.safetyNothing
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = L.safetyConfirmTitle(snapshot.command)
        alert.informativeText = L.safetyConfirmBody(paths.count)
        alert.addButton(withTitle: L.safetyConfirmRestore)
        alert.addButton(withTitle: L.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = SafetyNet.restore(snapshot)
            DispatchQueue.main.async {
                guard let self else { return }
                self.showDropMessage(DropMessage(title: ok ? L.safetyRestored : L.safetyFailed, warning: nil))
                self.react(ok ? .joy : .scared)
                if ok, self.model.safetyNet?.snapshot.id == snapshot.id { self.model.safetyNet = nil }
                self.render()
            }
        }
    }

    /// Deletes every snapshot on this Mac after a confirmation.
    func clearSnapshots() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L.safetyClearConfirm
        alert.informativeText = L.safetyClearBody
        alert.addButton(withTitle: L.safetyDelete)
        alert.addButton(withTitle: L.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SafetyNet.clearAll()
        if model.safetyNet?.host == nil { model.safetyNet = nil }
        render()
    }

    /// Runs the project's tests in a login shell (so node, cargo and the
    /// like are on PATH), with CI=1 so watchers exit, for up to ten minutes.
    private func runTests(for receipt: TaskReceipt) {
        guard let cwd = receipt.cwd, model.testRun.map({ $0.state != .running }) ?? true else { return }
        if let host = receipt.host {
            let job = RemoteJob(kind: .tests, cwd: cwd)
            remoteJobReceipts[job.id] = receipt.id
            model.testRun = TestRun(receiptId: receipt.id, command: host, startedAt: Date(), state: .running)
            queue(job, host: host)
            render()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let found = TestRunner.detect(cwd: cwd) else { return }
            let started = Date()
            DispatchQueue.main.async {
                self?.model.testRun = TestRun(receiptId: receipt.id, command: found.command, startedAt: started, state: .running)
                self?.render()
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", found.command]
            process.currentDirectoryURL = URL(fileURLWithPath: found.root)
            process.environment = ProcessInfo.processInfo.environment.merging(["CI": "1"]) { _, new in new }
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            var timedOut = false
            let timer = DispatchWorkItem {
                if process.isRunning {
                    timedOut = true
                    process.terminate()
                }
            }
            var text = ""
            let launched = (try? process.run()) != nil
            if launched {
                DispatchQueue.global().asyncAfter(deadline: .now() + TestRunner.timeout, execute: timer)
                text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                timer.cancel()
            }
            // terminationStatus throws for a process that never started.
            let passed = launched && !timedOut && process.terminationReason == .exit && process.terminationStatus == 0
            let tail = TestRunner.tail(text) + (timedOut ? "\n" + L.testsTimedOut : "")
            DispatchQueue.main.async {
                guard let self, self.model.testRun?.receiptId == receipt.id else { return }
                self.model.testRun?.state = passed ? .passed : .failed(output: tail)
                self.model.testRun?.duration = Date().timeIntervalSince(started)
                self.react(passed ? .joy : .scared)
                self.render()
            }
        }
    }

    /// The reviewer's command line tool: the usual places, then the login shell's PATH.
    private static func binary(for agent: AgentKind) -> String? {
        let fm = FileManager.default
        if let path = CrossReview.candidates(agent).first(where: { fm.isExecutableFile(atPath: $0) }) { return path }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v " + (agent == .claude ? "claude" : "codex")]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        return process.terminationStatus == 0 && path.hasPrefix("/") ? path : nil
    }

    /// The other agent reads the task's diff and lists problems, read-only,
    /// in a login shell so a node-based CLI finds node.
    private func runReview(of receipt: TaskReceipt) {
        guard let cwd = receipt.cwd, model.review.map({ $0.state != .running }) ?? true else { return }
        let reviewer = CrossReview.reviewer(for: receipt.agent)
        let started = Date()
        model.review = ReviewRun(receiptId: receipt.id, author: receipt.agent, reviewer: reviewer, startedAt: started, state: .running)
        react(.think)
        render()
        if let host = receipt.host {
            let job = RemoteJob(kind: .review, cwd: cwd, files: receipt.files, author: receipt.agent, task: receipt.prompt)
            remoteJobReceipts[job.id] = receipt.id
            queue(job, host: host)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let state: ReviewRun.State
            if let binary = Self.binary(for: reviewer) {
                if let diff = CrossReview.diff(cwd: cwd, files: receipt.files) {
                    let root = CrossReview.projectRoot(cwd: cwd)
                    let prompt = CrossReview.prompt(author: receipt.agent, task: receipt.prompt, diff: diff)
                    state = Self.review(binary: binary, arguments: CrossReview.arguments(reviewer: reviewer, prompt: prompt), root: root)
                } else {
                    state = .failed(L.reviewNoChanges)
                }
            } else {
                state = .failed(L.reviewNotFound)
            }
            DispatchQueue.main.async {
                guard let self, self.model.review?.receiptId == receipt.id else { return }
                self.model.review?.state = state
                if case .done(_, let findings) = state { self.react(findings == 0 ? .joy : .idea) }
                self.render()
            }
        }
    }

    private static func review(binary: String, arguments: [String], root: String) -> ReviewRun.State {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "\"$0\" \"$@\"", binary] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .failed("—") }
        var timedOut = false
        let timer = DispatchWorkItem {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + CrossReview.timeout, execute: timer)
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        timer.cancel()
        if timedOut { return .failed(L.testsTimedOut) }
        guard process.terminationStatus == 0, !text.isEmpty else {
            return .failed(TestRunner.tail(text, lines: 3).isEmpty ? "exit \(process.terminationStatus)" : TestRunner.tail(text, lines: 3))
        }
        return .done(text: text, findings: CrossReview.findings(in: text))
    }

    private func copyReview() {
        guard let review = model.review, case .done(let text, _) = review.state else { return }
        copyToPasteboard(L.reviewAgentMessage(review.reviewer, text))
        showDropMessage(DropMessage(title: L.reviewCopied(review.author), warning: nil))
    }

    private func copyTestFailure() {
        guard let run = model.testRun, case .failed(let output) = run.state else { return }
        copyToPasteboard(L.testsAgentMessage(run.command, output))
        showDropMessage(DropMessage(title: L.testsCopied, warning: nil))
    }

    // MARK: - Night shift

    func addNightJob(_ job: NightJob) {
        nightJobs.append(job)
        NightShift.save(nightJobs)
        if let host = job.host { queue(RemoteJob(night: job), host: host) }
    }

    /// Cancels a waiting job, stops a running one, or forgets a finished one.
    func removeNightJob(id: String) {
        guard let job = nightJobs.first(where: { $0.id == id }) else { return }
        switch job.state {
        case .waiting, .running:
            if let host = job.host {
                queue(RemoteJob(kind: .cancel, target: id), host: host, quietly: true)
            } else if case .running = job.state {
                nightProcess?.terminate()
            }
        default:
            break
        }
        nightJobs.removeAll { $0.id == id }
        NightShift.save(nightJobs)
    }

    /// Where the newest session on this Mac (nil) or a server works: the default folder for a new job.
    func recentFolder(host: String?) -> String? {
        store.orderedSessions.first { $0.host == host && $0.cwd != nil }?.cwd
    }

    /// Servers that sent events or reports, newest first.
    var knownHosts: [String] {
        remoteSeen.sorted { $0.value > $1.value }.map(\.key)
    }

    // MARK: - Server jobs

    private static var serverJobsURL: URL { BridgePaths.directory().appendingPathComponent("server-jobs.json") }

    /// Jobs not yet acknowledged by servers, their receipts and applied results:
    /// saved on every change, so an app restart loses nothing.
    private var serverJobs = JobOutbox.load(from: AgentsController.serverJobsURL) {
        didSet { serverJobs.save(to: Self.serverJobsURL) }
    }

    /// Jobs wait here until that server's worker has stored them.
    private var remoteJobs: [String: [RemoteJob]] {
        get { serverJobs.waiting }
        set { serverJobs.waiting = newValue }
    }
    private var workerSeen: [String: Date] = [:]
    /// Job id -> the receipt it belongs to.
    private var remoteJobReceipts: [String: String] {
        get { serverJobs.receipts }
        set { serverJobs.receipts = newValue }
    }

    private func queue(_ job: RemoteJob, host: String, quietly: Bool = false) {
        remoteJobs[host, default: []].append(job)
        if !quietly, Date().timeIntervalSince(workerSeen[host] ?? .distantPast) > 30 {
            showDropMessage(DropMessage(title: L.serverJobWaits(host), warning: nil))
        }
    }

    /// Main thread. A worker hands in results and the ids of jobs it has stored,
    /// and gets every job of its server not acknowledged yet (see JobOutbox).
    private func jobsRequested(host: String, results: [RemoteJobResult], received: [String]?) -> [RemoteJob] {
        workerSeen[host] = Date()
        remoteSeen[host] = Date()
        // Worked on a copy and saved only if something changed: the worker asks every few seconds.
        var outbox = serverJobs
        let fresh = outbox.fresh(results)
        let jobs = outbox.deliver(host: host, received: received)
        if outbox != serverJobs { serverJobs = outbox }
        for result in fresh { apply(result, host: host) }
        if !fresh.isEmpty { render() }
        return jobs
    }

    private func apply(_ result: RemoteJobResult, host: String) {
        let receiptId = remoteJobReceipts[result.id]
        switch result.kind {
        case .tests:
            guard let receiptId, model.testRun?.receiptId == receiptId, model.testRun?.state == .running else { return }
            let state: TestRun.State
            switch result.state {
            case "passed": state = .passed
            case "none": state = .unavailable(L.testsNoneOnServer)
            default: state = .failed(output: result.output ?? "")
            }
            model.testRun = TestRun(receiptId: receiptId, command: result.command ?? host,
                                    startedAt: model.testRun?.startedAt ?? Date(), state: state, duration: result.duration)
            if state == .passed { react(.joy) } else if case .failed = state { react(.scared) }
        case .review:
            guard let receiptId, model.review?.receiptId == receiptId, model.review?.state == .running else { return }
            if result.state == "done", let text = result.output {
                let findings = CrossReview.findings(in: text)
                model.review?.state = .done(text: text, findings: findings)
                react(findings == 0 ? .joy : .idea)
            } else {
                model.review?.state = .failed(result.output ?? "—")
            }
        case .lines:
            guard let receiptId, model.receipt?.id == receiptId, result.state == "done" else { return }
            model.receipt?.added = result.added
            model.receipt?.removed = result.removed
        case .night:
            guard let index = nightJobs.firstIndex(where: { $0.id == result.id }) else { return }
            let job = nightJobs[index]
            let place = (job.folder as NSString).lastPathComponent + " · " + host
            switch result.state {
            case "running":
                nightJobs[index].state = .running(since: Date())
                telegram.send("🌙 " + L.nightStarted(job.agent, place))
            case "done":
                nightJobs[index].state = .done(at: Date())
                telegram.send("🌙 " + L.nightDone(job.agent, place))
            case "failed":
                nightJobs[index].state = .failed(at: Date(), reason: result.output ?? "—")
                telegram.send("🌙 " + L.nightFailed(job.agent, place, result.output ?? "—"))
            default:
                break
            }
            NightShift.save(nightJobs)
        case .cancel:
            break
        }
    }

    func renewTrigger(for agent: AgentKind) -> NightJob.Trigger {
        NightShift.renewTrigger(model.summary.limits[agent])
    }

    private func startDueNightJob() {
        guard nightProcess == nil,
              let index = nightJobs.firstIndex(where: { $0.host == nil && NightShift.isDue($0, limits: model.summary.limits[$0.agent]) })
        else { return }
        let job = nightJobs[index]
        guard let binary = Self.binary(for: job.agent), FileManager.default.fileExists(atPath: job.folder) else {
            finishNightJob(id: job.id, state: .failed(at: Date(), reason: L.reviewNotFound))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "\"$0\" \"$@\"", binary] + NightShift.arguments(job)
        process.currentDirectoryURL = URL(fileURLWithPath: job.folder)
        process.environment = ProcessInfo.processInfo.environment.merging([NightShift.environmentKey: job.id]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                let ok = finished.terminationReason == .exit && finished.terminationStatus == 0
                self?.finishNightJob(id: job.id, state: ok ? .done(at: Date())
                                     : .failed(at: Date(), reason: "exit \(finished.terminationStatus)"))
            }
        }
        guard (try? process.run()) != nil else {
            finishNightJob(id: job.id, state: .failed(at: Date(), reason: "—"))
            return
        }
        nightProcess = process
        nightJobs[index].state = .running(since: Date())
        NightShift.save(nightJobs)
        telegram.send("🌙 " + L.nightStarted(job.agent, (job.folder as NSString).lastPathComponent))
        // A runaway job is stopped after a few hours.
        DispatchQueue.main.asyncAfter(deadline: .now() + NightShift.timeout) { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
        updateAwake()
    }

    private func finishNightJob(id: String, state: NightJob.State) {
        nightProcess = nil
        guard let index = nightJobs.firstIndex(where: { $0.id == id }) else { return }
        nightJobs[index].state = state
        NightShift.save(nightJobs)
        let job = nightJobs[index]
        let place = (job.folder as NSString).lastPathComponent
        if case .failed(_, let reason) = state {
            telegram.send("🌙 " + L.nightFailed(job.agent, place, reason))
        } else {
            telegram.send("🌙 " + L.nightDone(job.agent, place))
        }
        updateAwake()
        render()
    }

    private func show(page: NotchPage) {
        guard page != model.page else { return }
        model.page = page
        ViewSettings.page = page
        render()
    }

    /// Two fingers sideways on the open notch flip between Overview and
    /// Stats; vertical scrolling of a long notch is left alone.
    private func handleSwipe(_ event: NSEvent) -> NSEvent? {
        guard model.mode == .expanded, event.window === panel, event.hasPreciseScrollingDeltas,
              event.momentumPhase.isEmpty,
              StatsPage.hasContent(model.summary, visible: model.visibleCards) else { return event }
        if event.phase == .began {
            swipe = .zero
            swipeDone = false
        }
        swipe.dx += event.scrollingDeltaX
        swipe.dy += event.scrollingDeltaY
        let sideways = abs(swipe.dx) > abs(swipe.dy) * 1.5
        if !swipeDone, sideways, abs(swipe.dx) > 40 {
            swipeDone = true
            // Where the fingers went, whatever the natural scrolling setting.
            let fingersLeft = (event.isDirectionInvertedFromDevice ? swipe.dx : -swipe.dx) < 0
            show(page: fingersLeft ? .stats : .overview)
        }
        return sideways ? nil : event
    }

    func toggleQuiet() {
        settings.quietUntil = settings.isQuiet ? nil : Date().addingTimeInterval(3600)
        render()
    }

    func refreshNow() {
        collector.refresh()
        react(.think)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func showDropMessage(_ message: DropMessage) {
        model.dropMessage = message
        dropMessageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.model.dropMessage = nil
            self?.render()
        }
        dropMessageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        render()
    }

    private func peek(_ content: PeekContent, cooldown: TimeInterval = AgentsController.peekCooldown,
                      duration: TimeInterval = AgentsController.peekDuration) {
        guard !settings.isQuiet, Date().timeIntervalSince(lastPeek) > cooldown, desiredMode() != .expanded else { return }
        lastPeek = Date()
        model.peek = content
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.model.peek = nil
            self?.render()
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        render()
    }

    private func desiredMode() -> NotchMode {
        if hovering || !store.approvals.isEmpty || model.dropTargeted || model.dropMessage != nil { return .expanded }
        if model.peek != nil { return .peek }
        if !store.sessions.isEmpty { return .compact }
        // A limit close to running out stays in sight even with no agent running.
        if let limit = model.restingLimit, limit.window.percent >= 80 { return .compact }
        return .hidden
    }

    /// Main thread only.
    private func react(_ reaction: DennyReaction) {
        let play = DennyReactionPlay(reaction: reaction)
        model.reaction = play
        DispatchQueue.main.asyncAfter(deadline: .now() + DennyReaction.duration) { [weak self] in
            if self?.model.reaction == play { self?.model.reaction = nil }
        }
    }

    private func handleHover(_ isHovering: Bool) {
        collapseWork?.cancel()
        if isHovering {
            hovering = true
            render()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.hovering = false
            self?.render()
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    // MARK: - Panel

    private func setUpPanel() {
        guard let screen = targetScreen() else { return }
        let notch = notchFrame(on: screen)
        let panel = NotchPanel(contentRect: notch)
        let view = AgentsNotchView(
            model: model,
            onAnswer: { [weak self] id, decision in self?.answer(id: id, decision: decision) },
            onHover: { [weak self] isHovering in self?.handleHover(isHovering) },
            onOpenFullDenny: { NSWorkspace.shared.open(AgentsController.fullDennyURL) },
            onDropFiles: { [weak self] urls in self?.handleDrop(urls) },
            onResetCodex: { [weak self] in self?.confirmCodexReset() },
            actions: NotchActions(
                quiet: { [weak self] in self?.toggleQuiet() },
                refresh: { [weak self] in self?.refreshNow() },
                settings: { [weak self] in self?.onOpenSettings() },
                relay: { [weak self] key, limit in self?.copyRelayNote(sessionKey: key, becauseOfLimit: limit) },
                dismissRelay: { [weak self] in
                    self?.model.relayOffer = nil
                    self?.render()
                },
                undoSnapshot: { [weak self] notice in self?.undo(notice) },
                copyReceipt: { [weak self] receipt in
                    self?.copyToPasteboard(ReceiptCard.text(receipt))
                    self?.showDropMessage(DropMessage(title: L.receiptCopied, warning: nil))
                },
                dismissReceipt: { [weak self] in
                    self?.model.receipt = nil
                    self?.render()
                },
                runTests: { [weak self] receipt in self?.runTests(for: receipt) },
                sendTestFailure: { [weak self] in self?.copyTestFailure() },
                runReview: { [weak self] receipt in self?.runReview(of: receipt) },
                sendReview: { [weak self] in self?.copyReview() },
                dismissReview: { [weak self] in
                    self?.model.review = nil
                    self?.render()
                },
                dismissSnapshot: { [weak self] in
                    self?.model.safetyNet = nil
                    self?.render()
                }
            )
        )
        dropObserver = model.$dropTargeted.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.render() }
        }
        let hosting = FirstClickHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: notch.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        if !settings.showInFullScreen { panel.collectionBehavior.remove(.fullScreenAuxiliary) }
        panel.orderFrontRegardless()
        self.panel = panel
        model.notchHeight = notch.height
    }

    fileprivate func targetScreen() -> NSScreen? {
        if let name = settings.display, let chosen = NSScreen.screens.first(where: { $0.localizedName == name }) {
            return chosen
        }
        return NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func notchFrame(on screen: NSScreen) -> CGRect {
        let input = NotchGeometryInput(
            screenFrame: screen.frame,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
            safeAreaInsetsTop: screen.safeAreaInsets.top
        )
        return NotchGeometry.compute(input: input, fineTune: .zero).closedFrame
    }

    private func layout(animated: Bool) {
        guard let panel, let screen = targetScreen() else { return }
        let notch = notchFrame(on: screen)
        model.notchHeight = notch.height
        let size: CGSize
        switch model.mode {
        case .hidden:
            size = notch.size
        case .compact:
            size = CGSize(width: notch.width + 2 * 80, height: notch.height)
        case .peek:
            let below: CGFloat
            switch model.peek {
            case .finished?: below = 116
            case .celebration?: below = 238
            default: below = 120
            }
            size = CGSize(width: max(notch.width + 2 * 28, 230), height: notch.height + below)
        case .expanded:
            let width = max(notch.width + 2 * 160, 540)
            size = CGSize(width: width, height: expandedHeight(width: width))
        }
        let frame = CGRect(
            x: notch.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.allowsKeyWhileOpen = model.mode == .expanded
        updateAccessories(island: frame)
        guard panel.frame != frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}

extension AgentsController {
    /// Lets SwiftUI lay the open notch out at the given width and reports
    /// the height it needs, capped to most of the screen.
    fileprivate func expandedHeight(width: CGFloat) -> CGFloat {
        let content = ExpandedContent(model: model, onAnswer: { _, _ in }, onOpenFullDenny: {}, measuring: true)
            .frame(width: width)
        let measure = NSHostingView(rootView: content)
        let height = measure.fittingSize.height
        let limit = (targetScreen()?.visibleFrame.height ?? 800) * 0.85
        let scroll = height > limit
        if model.needsScroll != scroll { model.needsScroll = scroll }
        return min(max(height, 120), limit)
    }
}

/// Buttons in the notch must work on the first click, without first
/// making the (non-activating) panel key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
