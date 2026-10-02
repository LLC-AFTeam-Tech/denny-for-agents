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
