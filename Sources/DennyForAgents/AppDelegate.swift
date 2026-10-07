import AgentCore
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = AgentsController()
    private var statusItem: NSStatusItem?
    private lazy var settingsModel = SettingsModel(
        notifier: controller.notifier,
        lidGuard: controller.lidGuard,
        remoteSetup: { [weak self] in self?.controller.remoteSetup },
        remoteHosts: { [weak self] in self?.controller.remoteHosts ?? [] },
        onAgentsChanged: { [weak self] in self?.controller.refreshHooksState() },
        onAwakeChanged: { [weak self] in self?.controller.updateAwake() }
    )
    private lazy var trayPanel = TrayPanelController(
        model: settingsModel,
        button: statusItem?.button,
        onFullDenny: { NSWorkspace.shared.open(AgentsController.fullDennyURL) }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAnotherInstanceRunning() {
            NSApp.terminate(nil)
            return
        }
        // Remember the language this launch uses, so Settings can offer a restart after a change.
        UserDefaults.standard.set(AppSettings.shared.language?.rawValue, forKey: "languageAtLaunch")
        HookSetup.refreshBinaryIfNeeded()
        setUpStatusItem()
        controller.onOpenSettings = { [weak self] in self?.openSettings() }
        settingsModel.serverLoads = { [weak self] in self?.controller.serverLoads ?? [] }
        settingsModel.sshSource = { [weak self] in
            guard let manager = self?.controller.ssh else { return [] }
            return manager.servers.map { server in
                switch manager.states[server.id] {
                case .connected(_, let since)?:
                    return .init(id: server.id, destination: server.destination,
                                 status: L.sshConnected(Fmt.relative(since, now: Date())), mood: .ok, needsKey: false)
                case .failed(let failure, let retryAt)?:
                    let wait = Fmt.countdown(max(0, retryAt.timeIntervalSinceNow))
                    return .init(id: server.id, destination: server.destination,
                                 status: SSHTunnelManager.describe(failure) + " · " + L.sshRetry(wait),
                                 mood: .problem, needsKey: failure == .needsKey)
                case .connecting?, nil:
                    return .init(id: server.id, destination: server.destination,
                                 status: L.sshConnecting, mood: .waiting, needsKey: false)
                }
            }
        }
        settingsModel.addSSH = { [weak self] destination in self?.controller.ssh.add(destination: destination) ?? false }
        settingsModel.removeSSH = { [weak self] id, unhook in self?.controller.ssh.remove(id: id, uninstallHooks: unhook) }
        settingsModel.installSSH = { [weak self] id, done in
            guard let self else { return done(nil) }
            self.controller.ssh.installHooks(id: id, done: done)
        }
        controller.ssh.onChange = { [weak self] in self?.settingsModel.refresh() }
        settingsModel.safetySnapshots = { [weak self] in self?.controller.safetySnapshots ?? [] }
        settingsModel.undoSnapshot = { [weak self] notice in self?.controller.undo(notice) }
        settingsModel.officeTasks = { [weak self] in self?.controller.office.tasks ?? [] }
        settingsModel.addOfficeTask = { [weak self] prompt, agent, folder, host in
            self?.controller.office.add(prompt: prompt, agent: agent, folder: folder, host: host)
        }
        settingsModel.reworkOfficeTask = { [weak self] id, remarks in self?.controller.office.rework(id: id, remarks: remarks) }
        settingsModel.officeSettings = { [weak self] in self?.controller.office.settings ?? OfficeSettings() }
        settingsModel.updateOfficeSettings = { [weak self] change in self?.controller.office.updateSettings(change) }
        settingsModel.addOfficeRecurring = { [weak self] item in self?.controller.office.addRecurring(item) }
        settingsModel.removeOfficeRecurring = { [weak self] id in self?.controller.office.removeRecurring(id: id) }
        settingsModel.stopOfficeTask = { [weak self] id in self?.controller.office.stop(id: id) }
        settingsModel.acceptOfficeTask = { [weak self] id, done in self?.controller.office.accept(id: id, done: done) }
        settingsModel.discardOfficeTask = { [weak self] id in self?.controller.office.discard(id: id) }
        settingsModel.forgetOfficeTask = { [weak self] id in self?.controller.office.forget(id: id) }
        controller.onOfficeChange = { [weak self] in self?.settingsModel.objectWillChange.send() }
        settingsModel.nightJobs = { [weak self] in self?.controller.nightJobs ?? [] }
        settingsModel.addNightJob = { [weak self] job in self?.controller.addNightJob(job) }
        settingsModel.removeNightJob = { [weak self] id in self?.controller.removeNightJob(id: id) }
        settingsModel.recentFolder = { [weak self] host in self?.controller.recentFolder(host: host) }
        settingsModel.knownHosts = { [weak self] in self?.controller.knownHosts ?? [] }
        settingsModel.renewTrigger = { [weak self] agent in self?.controller.renewTrigger(for: agent) ?? .limitRenews(resetsAt: nil) }
        settingsModel.clearSnapshots = { [weak self] in
            self?.controller.clearSnapshots()
            self?.settingsModel.objectWillChange.send()
        }
        controller.start()
        AppUpdater.shared.onNewVersion = { [weak self] version in
            self?.controller.notifier.post(title: L.updateAvailable(version), body: L.updateNotifyBody)
        }
        AppUpdater.shared.start()
        if !HookSetup.anyInstalled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.askToConnect()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let tray = Bundle.main.image(forResource: "TrayIcon") {
            tray.size = NSSize(width: 18, height: 18)
            item.button?.image = tray
        } else {
            item.button?.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Denny for Agents")
        }
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        statusItem = item
    }

    @objc private func openSettings() {
        trayPanel.show()
    }

    @objc private func statusItemClicked() {
        trayPanel.toggle()
    }

    @objc private func openFullDenny() {
        NSWorkspace.shared.open(AgentsController.fullDennyURL)
    }

    // MARK: - First run

    private func askToConnect() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L.connectTitle
        alert.informativeText = L.connectBody
        alert.addButton(withTitle: L.connect)
        alert.addButton(withTitle: L.later)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for agent in AgentKind.allCases {
            do {
                try HookSetup.setEnabled(true, agent: agent)
            } catch {
                showError(error)
            }
        }
        controller.refreshHooksState()
    }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L.setupFailed
        if case HookInstaller.InstallError.unreadableConfig(let path) = error {
            alert.informativeText = path
        } else {
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }

    private func isAnotherInstanceRunning() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .contains { $0.processIdentifier != mine }
    }
}
