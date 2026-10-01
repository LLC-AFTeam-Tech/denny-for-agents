import AgentCore
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = AgentsController()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAnotherInstanceRunning() {
            NSApp.terminate(nil)
            return
        }
        HookSetup.refreshBinaryIfNeeded()
        setUpStatusItem()
        controller.start()
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
        item.button?.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Denny for Agents")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "Denny for Agents", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        for agent in AgentKind.allCases {
            let item = NSMenuItem(
                title: agent == .claude ? L.menuClaude : L.menuCodex,
                action: #selector(toggleAgent(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = agent.rawValue
            item.state = HookInstaller.isInstalled(agent: agent) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(alertsItem())
        let remote = NSMenuItem(title: L.menuRemote, action: #selector(showRemoteSetup), keyEquivalent: "")
        remote.target = self
        menu.addItem(remote)
        menu.addItem(.separator())
        let full = NSMenuItem(title: L.menuFullDenny, action: #selector(openFullDenny), keyEquivalent: "")
        full.target = self
        menu.addItem(full)
        let quit = NSMenuItem(title: L.menuQuit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func toggleAgent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let agent = AgentKind(rawValue: raw) else { return }
        let enable = !HookInstaller.isInstalled(agent: agent)
        do {
            try HookSetup.setEnabled(enable, agent: agent)
        } catch {
            showError(error)
        }
        controller.refreshHooksState()
    }

    @objc private func showRemoteSetup() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        guard let setup = controller.remoteSetup else {
            alert.messageText = L.remoteUnavailable
            alert.runModal()
            return
        }
        alert.messageText = L.remoteTitle
        alert.informativeText = L.remoteBody(port: setup.port)
        alert.addButton(withTitle: L.copyCommand)
        alert.addButton(withTitle: L.close)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(RemoteBridge.installCommand(port: setup.port, token: setup.token), forType: .string)
        }
    }

    private func alertsItem() -> NSMenuItem {
        let settings = controller.notifier.settings
        let item = NSMenuItem(title: L.menuAlerts, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        func header(_ title: String) {
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            submenu.addItem(header)
        }
        func option(_ title: String, checked: Bool, apply: @escaping (inout AlertSettings) -> Void) {
            let option = NSMenuItem(title: title, action: #selector(applyAlertOption(_:)), keyEquivalent: "")
            option.target = self
            option.state = checked ? .on : .off
            option.indentationLevel = 1
            option.representedObject = AlertOption(apply: apply)
            submenu.addItem(option)
        }

        header(L.alertFinish)
        option(L.off, checked: settings.finishAfterMinutes == nil) { $0.finishAfterMinutes = nil }
        option(L.anyLength, checked: settings.finishAfterMinutes == 0) { $0.finishAfterMinutes = 0 }
        for minutes in [1, 2, 5, 10] {
            option(L.longerThan(minutes), checked: settings.finishAfterMinutes == minutes) { $0.finishAfterMinutes = minutes }
        }
        submenu.addItem(.separator())
        header(L.alertLimit)
        option(L.off, checked: settings.limitPercent == nil) { $0.limitPercent = nil }
        for percent in [70, 80, 90] {
            option(L.atPercent(percent), checked: settings.limitPercent == percent) { $0.limitPercent = percent }
        }
        submenu.addItem(.separator())
        header(L.alertBudget)
        option(L.off, checked: settings.dailyBudget == nil) { $0.dailyBudget = nil }
        for budget in [10.0, 25, 50, 100] {
            option("$\(Int(budget))", checked: settings.dailyBudget == budget) { $0.dailyBudget = budget }
        }
        item.submenu = submenu
        return item
    }

    @objc private func applyAlertOption(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? AlertOption else { return }
        var settings = controller.notifier.settings
        option.apply(&settings)
        controller.notifier.settings = settings
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

private final class AlertOption: NSObject {
    let apply: (inout AlertSettings) -> Void

    init(apply: @escaping (inout AlertSettings) -> Void) {
        self.apply = apply
    }
}
