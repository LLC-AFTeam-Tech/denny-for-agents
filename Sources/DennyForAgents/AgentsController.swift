import AgentCore
import AppKit
import Combine
import SwiftUI

/// Owns the agent model, the bridge server and the notch panel.
final class AgentsController {
    static let fullDennyURL = URL(string: "https://afteam.tech/denny/?utm_source=denny-for-agents")!

    let model = AgentsViewModel()
    fileprivate let face = DennyFaceViewModel()
    private var store = AgentStore()
    private let server = AgentBridgeServer()
    private let collector = UsageCollector()
    /// Latest report per machine: this Mac and every SSH server.
    private var reports: [String: UsageReport] = [:]
    /// Last time each SSH server reached Denny, by any event or report.
    private var remoteSeen: [String: Date] = [:]
    /// Relay offers already made or dismissed, so each shows once.
    private var relaySeen: Set<String> = []
    private var panel: NotchPanel?
    private var timer: Timer?
    private var hovering = false
    private var collapseWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?
    private var lastPeek = Date.distantPast
    static let peekDuration: TimeInterval = 5
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
        server.onEvent = { [weak self] event, requestId in
            self?.handle(event, requestId: requestId)
        }
        server.onFilesRequest = { [weak self] event in
            self?.deliverFiles(for: event) ?? []
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
        face.playGesture(.welcome)
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
                    self?.model.page = .overview
                    ViewSettings.page = .overview
                    self?.render()
                },
                .init(symbol: "chart.bar.xaxis", title: L.pageStats, selected: model.page == .stats) { [weak self] in
                    self?.model.page = .stats
                    ViewSettings.page = .stats
                    self?.render()
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
        let hold = (settings.keepAwake && localWork) || settings.manualAwakeActive
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
        let effects = store.apply(event, requestId: requestId)
        for effect in effects {
            switch effect {
            case .celebrate(let key, let duration):
                face.playGesture(.joy)
                collector.refresh()
                if settings.peekOnFinish, let session = store.sessions[key] {
                    let detail = duration.map { L.finishedBody(session.projectName, Fmt.countdown($0)) } ?? session.projectName
                    peek(.finished(title: L.finishedTitle(session.agent), detail: detail), cooldown: Self.finishPeekCooldown)
                }
                if !settings.isQuiet, notifier.settings.notifiesFinish(after: duration), let session = store.sessions[key] {
                    notifier.post(title: L.finishedTitle(session.agent),
                                  body: L.finishedBody(session.projectName, duration.map(Fmt.countdown) ?? "—"))
                }
            case .startedStep(_, let kind):
                if settings.peekOnWriting { peek(.activity(kind == .writing ? .notes : .tasks)) }
            case .looksStuck(let key, let reason):
                guard settings.stuckAlerts, !settings.isQuiet, let session = store.sessions[key] else { break }
                face.playGesture(.misheard)
                let title = L.stuckTitle(session.agent)
                peek(.finished(title: title, detail: L.stuckReason(reason)), cooldown: Self.finishPeekCooldown)
                notifier.post(title: title, body: session.projectName + " · " + L.stuckReason(reason))
            case .turnStarted:
                if settings.peekOnStart { peek(.activity(.notes), cooldown: Self.taskPeekCooldown) }
                // Racing a limit: Denny buckles down at the start of each task.
                if let limit = model.restingLimit, limit.window.percent >= 80 {
                    face.playGesture(.focus)
                }
            case .needsAttention(let id):
                // Denny reacts to what is being asked: calm, wary or scared.
                switch store.approvals.first(where: { $0.id == id })?.risk.level ?? .safe {
                case .safe, .caution:
                    face.playGesture(.confirmation)
                    NSSound(named: "Tink")?.play()
                case .danger:
                    face.playGesture(.oops)
                    NSSound(named: "Funk")?.play()
                case .critical:
                    face.playGesture(.connectionLost)
                    NSSound(named: "Basso")?.play()
                }
            }
        }
        render()
    }

    private func receive(_ report: UsageReport, from source: String) {
        reports[source] = report
        if source != "this-mac" { remoteSeen[report.host] = Date() }
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
        switch decision {
        case .allow: face.playGesture(.approval)
        case .deny: face.playGesture(.oops)
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
        }
        store.prune()
        refreshHooksState()
        if settings.quietUntil != nil, !settings.isQuiet { settings.quietUntil = nil }
        updateAwake()
        model.summary = UsageSummary.combine(Array(reports.values))
        render()
    }

    // MARK: - Rendering

    private func render() {
        model.update(from: store)
        updateAwake()
        updateFace()
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
        face.playGesture(.idea)
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
            face.playGesture(.approval)
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
        face.playGesture(.idea)
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
        face.playGesture(.approval)
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
            face.playGesture(.joy)
            peek(.finished(title: L.renewedTitle(limit.agent), detail: detail), cooldown: Self.finishPeekCooldown)
        }
        var tracker = notifier.tracker
        for alert in tracker.limitAlerts(model.summary, settings: settings) {
            let left = (alert.window.resetsAt ?? 0) - Date().timeIntervalSince1970
            let body = L.limitDetail(alert.window, resetsIn: left > 0 ? Fmt.countdown(left) : nil)
            if !quiet { notifier.post(title: L.limitAlertTitle(alert.agent, Int(alert.window.percent.rounded())), body: body) }
            face.playGesture(.oops)
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
            if outcome == "reset" { self.face.playGesture(.joy) }
            self.collector.refresh()
        }
    }

    func toggleQuiet() {
        settings.quietUntil = settings.isQuiet ? nil : Date().addingTimeInterval(3600)
        render()
    }

    func refreshNow() {
        collector.refresh()
        face.playGesture(.thinking)
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

    private func peek(_ content: PeekContent, cooldown: TimeInterval = AgentsController.peekCooldown) {
        guard !settings.isQuiet, Date().timeIntervalSince(lastPeek) > cooldown, desiredMode() != .expanded else { return }
        lastPeek = Date()
        model.peek = content
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.model.peek = nil
            self?.render()
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekDuration, execute: work)
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

    private func updateFace() {
        let presentation: NotchPresentationState
        let emotion: DennyFaceEmotion
        switch store.mood {
        case .idle:
            presentation = .idle
            if model.limitAlmostUsed {
                emotion = .unsure
            } else {
                emotion = store.sessions.isEmpty ? .calm : .satisfied
            }
        case .working:
            presentation = .thinking
            emotion = .thinking
        case .needsYou:
            presentation = .notification
            let risk = store.approvals.map(\.risk.level).max() ?? .safe
            emotion = risk >= .danger ? .surprise : (risk == .caution ? .unsure : .curiosity)
        }
        face.update(presentationState: presentation, emotion: emotion, age: .child, mouthPose: .rest, reduceMotion: false)
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
            face: face,
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
            size = CGSize(width: notch.width + 2 * 64, height: notch.height)
        case .peek:
            size = CGSize(width: max(notch.width + 2 * 64, 230), height: notch.height + 120)
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
        let content = ExpandedContent(model: model, face: face, onAnswer: { _, _ in }, onOpenFullDenny: {}, measuring: true)
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
