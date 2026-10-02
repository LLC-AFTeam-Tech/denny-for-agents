import AgentCore
import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case agents, servers, load, safetyNet, phone, nightShift, notch, cards, alerts, language, privacy, about

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .agents: return "cpu"
        case .servers: return "server.rack"
        case .load: return "speedometer"
        case .safetyNet: return "lifepreserver"
        case .phone: return "iphone"
        case .nightShift: return "moon.stars"
        case .notch: return "rectangle.topthird.inset.filled"
        case .cards: return "square.grid.2x2"
        case .alerts: return "bell"
        case .language: return "globe"
        case .privacy: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

/// What the settings window needs from the running app.
final class SettingsModel: ObservableObject {
    struct Host: Identifiable {
        let name: String
        let lastSeen: Date
        var id: String { name }
    }

    @Published var installed: [AgentKind: Bool] = [:]
    @Published var hosts: [Host] = []
    @Published var alerts: AlertSettings {
        didSet { notifier.settings = alerts }
    }
    @Published var section: SettingsSection = .agents
    @Published var setupError: String?

    @Published var lidRuleInstalled = false
    @Published var awakeDurationHours = 2
    @Published var awakeUntilTime = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
    @Published var awakeUsesUntil = false

    let notifier: Notifier
    let lidGuard: LidSleepGuard
    let remoteSetup: () -> (port: UInt16, token: String)?
    let remoteHosts: () -> [(name: String, lastSeen: Date)]
    var serverLoads: () -> [(host: String, system: UsageReport.System, at: Date)] = { [] }
    var safetySnapshots: () -> [SafetyNetNotice] = { [] }
    var undoSnapshot: (SafetyNetNotice) -> Void = { _ in }
    var clearSnapshots: () -> Void = {}
    var nightJobs: () -> [NightJob] = { [] }
    var addNightJob: (NightJob) -> Void = { _ in }
    var removeNightJob: (String) -> Void = { _ in }
    var recentFolder: () -> String? = { nil }
    var renewTrigger: (AgentKind) -> NightJob.Trigger = { _ in .limitRenews(resetsAt: nil) }
    /// Read by the hooks from ~/.denny-for-agents/safety-net/settings.json.
    @Published var safetySettings = SafetyNetSettings.load() {
        didSet { safetySettings.save() }
    }
    private let systemStats = SystemStats()
    @Published var mac: SystemStats.Snapshot?
    @Published var servers: [ServerLoad] = []

    struct ServerLoad: Identifiable {
        let host: String
        let system: UsageReport.System
        let at: Date
        var id: String { host }
    }
    let onAgentsChanged: () -> Void
    let onAwakeChanged: () -> Void

    init(notifier: Notifier, lidGuard: LidSleepGuard, remoteSetup: @escaping () -> (port: UInt16, token: String)?,
         remoteHosts: @escaping () -> [(name: String, lastSeen: Date)],
         onAgentsChanged: @escaping () -> Void, onAwakeChanged: @escaping () -> Void) {
        self.remoteHosts = remoteHosts
        self.notifier = notifier
        self.alerts = notifier.settings
        self.lidGuard = lidGuard
        self.remoteSetup = remoteSetup
        self.onAgentsChanged = onAgentsChanged
        self.onAwakeChanged = onAwakeChanged
        refresh()
    }

    func startManualAwake() {
        let settings = AppSettings.shared
        if awakeUsesUntil {
            var until = awakeUntilTime
            // "Until 9:00" chosen in the evening means tomorrow morning.
            if until <= Date() { until = Calendar.current.date(byAdding: .day, value: 1, to: until) ?? until }
            settings.awakeUntil = until
        } else {
            settings.awakeUntil = awakeDurationHours == 0 ? .distantFuture : Date().addingTimeInterval(TimeInterval(awakeDurationHours * 3600))
        }
        onAwakeChanged()
    }

    func stopManualAwake() {
        AppSettings.shared.awakeUntil = nil
        onAwakeChanged()
    }

    func setLidClosed(_ on: Bool) {
        if on, !lidGuard.isInstalled, !lidGuard.install() {
            refresh()
            return
        }
        AppSettings.shared.keepAwakeLidClosed = on
        refresh()
        onAwakeChanged()
    }

    func refresh() {
        installed = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0, HookInstaller.isInstalled(agent: $0)) })
        lidRuleInstalled = lidGuard.isInstalled
        hosts = remoteHosts().map { Host(name: $0.name, lastSeen: $0.lastSeen) }
        mac = systemStats.sample()
        servers = serverLoads().map { ServerLoad(host: $0.host, system: $0.system, at: $0.at) }
    }

    func setAgent(_ agent: AgentKind, enabled: Bool) {
        do {
            try HookSetup.setEnabled(enabled, agent: agent)
            setupError = nil
        } catch HookInstaller.InstallError.unreadableConfig(let path) {
            setupError = L.setupFailed + ": " + path
        } catch {
            setupError = L.setupFailed + ": " + error.localizedDescription
        }
        refresh()
        onAgentsChanged()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var telegram = TelegramBridge.shared
    @State private var botToken = ""
    @State private var nightAgent: AgentKind = .claude
    @State private var nightFolder = ""
    @State private var nightPrompt = ""
    @State private var nightAtTime = false
    @State private var nightTime = Calendar.current.date(bySettingHour: 3, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var hoveredSection: SettingsSection?

    /// Called by the footer buttons.
    var onFullDenny: () -> Void = {}
    var onQuit: () -> Void = {}

    /// The tray panel, styled after Vorssaint's: logo on top, section icons in
    /// a pill, dark cards, pill buttons at the bottom.
    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 4) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 40, height: 40)
                Text(L.settingsSection(model.section))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(.top, 14)
            HStack(spacing: 2) {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        model.section = section
                    } label: {
                        Image(systemName: section.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 30, height: 28)
                            .foregroundColor(model.section == section ? .black : .white.opacity(0.75))
                            .background(Capsule().fill(model.section == section ? Color(red: 0.55, green: 0.9, blue: 0.55) : .clear))
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering { hoveredSection = section } else if hoveredSection == section { hoveredSection = nil }
                    }
                    // .help() doesn't show in the tray popover, so draw the hint.
                    .overlay(alignment: .bottom) {
                        if hoveredSection == section {
                            TooltipLabel(text: L.settingsSection(section))
                                .offset(y: 30)
                                .allowsHitTesting(false)
                        }
                    }
                    .zIndex(hoveredSection == section ? 1 : 0)
                }
            }
            .padding(4)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .zIndex(1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch model.section {
                    case .agents: agents
                    case .servers: servers
                    case .load: load
                    case .safetyNet: safetyNet
                    case .phone: phone
                    case .nightShift: nightShift
                    case .notch: notch
                    case .cards: cards
                    case .alerts: alerts
                    case .language: language
                    case .privacy: privacy
                    case .about: about
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            HStack(spacing: 10) {
                PillButton(title: L.menuFullDenny, symbol: "sparkles", action: onFullDenny)
                PillButton(title: L.menuQuit, symbol: "power", action: onQuit)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(width: 400, height: 560)
        .background(LinearGradient(colors: [Color(red: 0.13, green: 0.14, blue: 0.27), Color(red: 0.07, green: 0.08, blue: 0.16)],
                                   startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .dark)
        .toggleStyle(.switch)
        .controlSize(.small)
        // Keep "last seen" and connection states current while the panel is open.
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in model.refresh() }
    }

    // MARK: - Sections

    @ViewBuilder private var agents: some View {
        PanelCard {
            ForEach(AgentKind.allCases, id: \.self) { agent in
                HStack(spacing: 10) {
                    AgentMark(agent: agent, size: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.displayName).font(.headline)
                        Text(HookInstaller.configURL(for: agent).path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    let on = model.installed[agent] == true
                    Text(on ? L.connected : L.notConnected)
                        .foregroundColor(on ? .green : .secondary)
                    Button(on ? L.disconnect : L.connect) { model.setAgent(agent, enabled: !on) }
                }
            }
            if let error = model.setupError {
                Text(error).foregroundColor(.red).font(.caption)
            }
        } footer: {
            Text(L.agentsFooter).font(.caption).foregroundColor(.secondary)
        }
        PanelCard {
            Toggle(L.keepAwake, isOn: $settings.keepAwake)
            Text(L.keepAwakeFooter).font(.caption).foregroundColor(.secondary)
        } header: {
            Text("Keep Awake")
        }
        PanelCard(L.awakeManual) {
            Picker(L.awakeManual, selection: $model.awakeUsesUntil) {
                Text(L.awakeDuration).tag(false)
                Text(L.awakeUntil).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                if model.awakeUsesUntil {
                    DatePicker(L.awakeUntil, selection: $model.awakeUntilTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                } else {
                    Picker(L.awakeDuration, selection: $model.awakeDurationHours) {
                        ForEach([1, 2, 4, 8], id: \.self) { hours in Text(L.hoursOnly(hours)).tag(hours) }
                        Text(L.awakeIndefinite).tag(0)
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                Spacer()
                if settings.manualAwakeActive {
                    Button(L.awakeStop) { model.stopManualAwake() }
                } else {
                    Button(L.awakeStart) { model.startManualAwake() }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let until = settings.awakeUntil, settings.manualAwakeActive {
                Text(until == .distantFuture ? L.awakeUntilOff : L.awakeActiveUntil(Fmt.time(until)))
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
        PanelCard {
            Toggle(L.lidClosed, isOn: Binding(
                get: { settings.keepAwakeLidClosed },
                set: { model.setLidClosed($0) }
            ))
            Text(L.lidWarning).font(.caption).foregroundColor(.orange)
            if settings.keepAwakeLidClosed, !LidSleepGuard.onACPower {
                Text(L.lidNeedsPower).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder private var servers: some View {
        PanelCard(L.serversConnected) {
            if model.hosts.isEmpty {
                Text(L.noServers).foregroundColor(.secondary)
            } else {
                ForEach(model.hosts) { host in
                    HStack {
                        Image(systemName: "server.rack")
                        Text(host.name)
                        Spacer()
                        Text(L.lastSeen(Fmt.relative(host.lastSeen, now: Date())))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        PanelCard {
            if let setup = model.remoteSetup() {
                Text(L.remoteBody(port: setup.port))
                    .font(.callout)
                    .textSelection(.enabled)
                HStack {
                    Spacer()
                    Button(L.copyCommand) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(RemoteBridge.installCommand(port: setup.port, token: setup.token),
                                                       forType: .string)
                    }
                }
            } else {
                Text(L.remoteUnavailable).foregroundColor(.red)
            }
        } header: {
            Text(L.remoteTitle)
        }
    }

    @ViewBuilder private var load: some View {
        if let mac = model.mac {
            PanelCard(L.thisMac) {
                LoadRow(title: L.cpu, value: mac.cpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "…",
                        fraction: mac.cpu ?? 0)
                LoadRow(title: L.memory,
                        value: "\(Fmt.bytes(Double(mac.memoryUsed))) / \(Fmt.bytes(Double(mac.memoryTotal)))",
                        fraction: Double(mac.memoryUsed) / Double(max(mac.memoryTotal, 1)),
                        warn: mac.pressure >= 2)
                HStack {
                    Text(L.pressure(mac.pressure))
                        .foregroundColor(mac.pressure >= 4 ? .red : (mac.pressure >= 2 ? .orange : .green))
                    Spacer()
                    Text(L.swap(Fmt.bytes(Double(mac.swapUsed)))).foregroundColor(.secondary)
                }
                .font(.system(size: 11))
                Text(L.upFor(Fmt.countdown(mac.uptime))).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        if model.servers.isEmpty {
            PanelCard(L.serversConnected) {
                Text(L.noServerLoad).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        ForEach(model.servers) { server in
            let system = server.system
            PanelCard(server.host) {
                LoadRow(title: L.cpuLoad(system.cpus),
                        value: String(format: "%.2f · %.2f · %.2f", system.load1, system.load5, system.load15),
                        fraction: system.loadFraction, warn: system.loadFraction > 1)
                LoadRow(title: L.memory,
                        value: "\(Fmt.bytes(system.memTotal - system.memAvailable)) / \(Fmt.bytes(system.memTotal))",
                        fraction: system.memoryUsedFraction, warn: system.memoryLow)
                if system.memoryLow {
                    Text(L.memoryLowWarning).font(.system(size: 11, weight: .semibold)).foregroundColor(.orange)
                }
                HStack {
                    Text(L.swap(Fmt.bytes(system.swapUsed) + " / " + Fmt.bytes(system.swapTotal)))
                    Spacer()
                    Text(L.updated(Fmt.relative(server.at, now: Date())))
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                Text(L.upFor(Fmt.countdown(system.uptime))).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder private var notch: some View {
        PanelCard(L.menuReadout) {
            Picker(L.menuReadout, selection: $settings.readout) {
                Text(L.readoutTimer).tag(ReadoutKind.timer)
                Text(L.readoutLimit).tag(ReadoutKind.limit)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        PanelCard(L.peeksTitle) {
            Toggle(L.peekOnStart, isOn: $settings.peekOnStart)
            Toggle(L.peekOnWriting, isOn: $settings.peekOnWriting)
            Toggle(L.peekOnFinish, isOn: $settings.peekOnFinish)
        }
        PanelCard(L.displayTitle) {
            Picker(L.displayTitle, selection: $settings.display) {
                Text(L.displayAuto).tag(String?.none)
                ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            Toggle(L.showInFullScreen, isOn: $settings.showInFullScreen)
        }
    }

    @ViewBuilder private var cards: some View {
        PanelCard {
            ForEach(StatsCardKind.allCases, id: \.self) { card in
                Toggle(L.cardName(card), isOn: Binding(
                    get: { settings.visibleCards.contains(card) },
                    set: { on in
                        if on { settings.visibleCards.insert(card) } else { settings.visibleCards.remove(card) }
                    }
                ))
            }
        } footer: {
            Text(L.cardsFooter).font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder private var alerts: some View {
        PanelCard(L.alertFinish) {
            Picker(L.alertFinish, selection: $model.alerts.finishAfterMinutes) {
                Text(L.off).tag(Int?.none)
                Text(L.anyLength).tag(Int?.some(0))
                ForEach([1, 2, 5, 10, 20], id: \.self) { minutes in
                    Text(L.longerThan(minutes)).tag(Int?.some(minutes))
                }
            }
            .labelsHidden()
        }
        PanelCard {
            Toggle(L.stuckSetting, isOn: $settings.stuckAlerts)
        }
        PanelCard {
            Toggle(L.testsAutoSetting, isOn: $settings.autoRunTests)
            Text(L.testsAutoFooter).font(.caption).foregroundColor(.secondary)
        }
        PanelCard(L.alertLimit) {
            Picker(L.alertLimit, selection: $model.alerts.limitPercent) {
                Text(L.off).tag(Int?.none)
                ForEach([50, 70, 80, 90, 95], id: \.self) { percent in
                    Text(L.atPercent(percent)).tag(Int?.some(percent))
                }
            }
            .labelsHidden()
        }
        PanelCard {
            Toggle(L.alertBudget, isOn: Binding(
                get: { model.alerts.dailyBudget != nil },
                set: { model.alerts.dailyBudget = $0 ? (model.alerts.dailyBudget ?? 25) : nil }
            ))
            if model.alerts.dailyBudget != nil {
                HStack {
                    Text("$")
                    TextField("25", value: Binding(
                        get: { model.alerts.dailyBudget ?? 25 },
                        set: { model.alerts.dailyBudget = max(1, $0) }
                    ), format: .number)
                    .frame(width: 90)
                    Spacer()
                }
            }
        } footer: {
            Text(L.budgetAlertBody).font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder private var language: some View {
        PanelCard {
            Picker(L.settingsSection(.language), selection: $settings.language) {
                Text(L.languageSystem).tag(UILanguage?.none)
                ForEach(UILanguage.allCases, id: \.self) { language in
                    Text(Self.nativeName(language)).tag(UILanguage?.some(language))
                }
            }
            .labelsHidden()
            if settings.language != AppSettings.launchLanguageChoice {
                HStack {
                    Text(L.languageRestart).foregroundColor(.secondary)
                    Spacer()
                    Button(L.restartNow) { Self.relaunch() }
                }
            }
        }
    }

    @ViewBuilder private var privacy: some View {
        PanelCard(L.privacyReads) {
            Text(L.privacyReadsBody).font(.callout)
        }
        PanelCard(L.privacyNever) {
            Text(L.privacyNeverBody).font(.callout)
        }
        PanelCard {
            Button(L.removeAll, role: .destructive) { Self.confirmRemoveAll(model) }
        } footer: {
            Text(L.removeAllFooter).font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder private var safetyNet: some View {
        let notices = model.safetySnapshots()
        PanelCard(L.safetyCardTitle) {
            if notices.isEmpty {
                Text(L.safetyEmpty).font(.callout).foregroundColor(.secondary)
            }
            ForEach(Array(notices.prefix(20)), id: \.snapshot.id) { notice in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.snapshot.command)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text([Fmt.time(Date(timeIntervalSince1970: notice.snapshot.createdAt)),
                              (notice.snapshot.cwd as NSString).lastPathComponent,
                              notice.host].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(notice.host == nil ? L.safetyUndo : L.safetyCopyCommand) { model.undoSnapshot(notice) }
                }
            }
        }
        Text(L.safetyFooter).font(.caption).foregroundColor(.secondary)
        PanelCard(L.safetyStorage) {
            Picker(L.safetyKeepFor, selection: $model.safetySettings.days) {
                ForEach(SafetyNetSettings.dayChoices, id: \.self) { days in
                    Text(L.safetyKeep(days)).tag(days)
                }
            }
            Picker(L.safetyLimit, selection: $model.safetySettings.limitMB) {
                ForEach(SafetyNetSettings.limitChoicesGB, id: \.self) { gb in
                    Text(L.safetyGB(gb)).tag(gb * 1024)
                }
            }
            Text(L.safetyUsed(ByteCountFormatter.string(fromByteCount: SafetyNet.used(SafetyNet.load()), countStyle: .file)))
                .font(.callout)
                .foregroundColor(.secondary)
            Button(L.safetyClear) { model.clearSnapshots() }
        }
        Text(L.safetyLimitFooter).font(.caption).foregroundColor(.secondary)
    }

    @ViewBuilder private var phone: some View {
        PanelCard(L.phoneTitle) {
            if let chat = telegram.settings.chatId, let bot = telegram.settings.botName {
                Text(L.phoneConnected(telegram.settings.chatName ?? String(chat), bot)).font(.callout)
                Picker(L.phoneTitle, selection: Binding(get: { telegram.settings.alwaysSend },
                                                        set: { telegram.setAlwaysSend($0) })) {
                    Text(L.phoneWhenAway).tag(false)
                    Text(L.phoneAlways).tag(true)
                }
                .labelsHidden()
                Toggle(L.phoneFinished, isOn: Binding(get: { telegram.settings.sendFinished },
                                                      set: { telegram.setSendFinished($0) }))
                HStack {
                    Button(L.phoneTest) { telegram.send(L.phoneTestText, force: true) }
                    Button(L.phoneDisconnect) { telegram.disconnect() }
                }
            } else if let bot = telegram.settings.botName, let code = telegram.pairingCode {
                Text(L.phoneSendCode(bot)).font(.callout)
                Text(L.phoneTopicHint).font(.caption).foregroundColor(.secondary)
                Text(code).font(.system(size: 28, weight: .bold, design: .monospaced)).textSelection(.enabled)
                HStack {
                    if let link = telegram.botLink {
                        Button(L.phoneOpenBot) { NSWorkspace.shared.open(link) }
                    }
                    ProgressView().controlSize(.small)
                    Text(L.phoneWaiting).font(.caption).foregroundColor(.secondary)
                }
                Button(L.phoneDisconnect) { telegram.disconnect() }
            } else {
                Text(L.phoneSteps).font(.callout)
                SecureField(L.phoneTokenPlaceholder, text: $botToken)
                Button(L.phoneCheck) { telegram.connect(token: botToken) }
                    .disabled(botToken.trimmingCharacters(in: .whitespaces).isEmpty)
                if let error = telegram.error {
                    Text(error).font(.caption).foregroundColor(.orange)
                }
            }
        }
        Text(L.phoneFooter).font(.caption).foregroundColor(.secondary)
    }

    @ViewBuilder private var nightShift: some View {
        PanelCard(L.nightNewJob) {
            Picker(L.nightAgent, selection: $nightAgent) {
                ForEach(AgentKind.allCases, id: \.self) { agent in Text(agent.displayName).tag(agent) }
            }
            HStack {
                Text(nightFolder.isEmpty ? L.nightNoFolder : (nightFolder as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button(L.nightChooseFolder) { chooseNightFolder() }
            }
            TextEditor(text: $nightPrompt)
                .font(.system(size: 12))
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15)))
            Picker(L.nightWhen, selection: $nightAtTime) {
                Text(L.nightWhenRenews).tag(false)
                Text(L.nightWhenAt).tag(true)
            }
            if nightAtTime {
                DatePicker(L.nightWhenAt, selection: $nightTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            Button(L.nightQueue) { queueNightJob() }
                .disabled(nightFolder.isEmpty || nightPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear { if nightFolder.isEmpty { nightFolder = model.recentFolder() ?? "" } }
        let jobs = model.nightJobs()
        if !jobs.isEmpty {
            PanelCard(L.nightQueueTitle) {
                ForEach(jobs.reversed()) { job in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.prompt).font(.system(size: 12)).lineLimit(2)
                            Text("\(job.agent.shortName) · \((job.folder as NSString).lastPathComponent) · \(nightStatus(job))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            model.removeNightJob(job.id)
                            model.objectWillChange.send()
                        } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                }
            }
        }
        Text(L.nightFooter).font(.caption).foregroundColor(.secondary)
    }

    private func nightStatus(_ job: NightJob) -> String {
        switch job.state {
        case .waiting:
            switch job.trigger {
            case .at(let date): return L.nightWaitsUntil(Fmt.time(date))
            case .limitRenews(let resetsAt):
                return resetsAt.map { L.nightWaitsUntil(Fmt.time(Date(timeIntervalSince1970: $0))) } ?? L.nightWaitsForLimit
            }
        case .running(let since): return L.nightRunning(Fmt.countdown(Date().timeIntervalSince(since)))
        case .done(let at): return L.nightDoneAt(Fmt.time(at))
        case .failed(_, let reason): return L.nightFailedShort(reason)
        }
    }

    private func chooseNightFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if !nightFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: nightFolder) }
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { nightFolder = url.path }
    }

    private func queueNightJob() {
        var trigger = model.renewTrigger(nightAgent)
        if nightAtTime {
            // The next time this clock time comes round.
            var date = Calendar.current.nextDate(after: Date(), matching: Calendar.current.dateComponents([.hour, .minute], from: nightTime),
                                                 matchingPolicy: .nextTime) ?? nightTime
            if date < Date() { date = date.addingTimeInterval(86400) }
            trigger = .at(date)
        }
        model.addNightJob(NightJob(agent: nightAgent, folder: nightFolder,
                                   prompt: nightPrompt.trimmingCharacters(in: .whitespacesAndNewlines), trigger: trigger))
        nightPrompt = ""
        model.objectWillChange.send()
    }

    @ViewBuilder private var about: some View {
        PanelCard {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Denny for Agents").font(.title2.bold())
                    Text(L.version(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))
                        .foregroundColor(.secondary)
                }
            }
            Text(L.aboutBody).font(.callout)
            Button(L.menuFullDenny) { NSWorkspace.shared.open(AgentsController.fullDennyURL) }
        }
        PanelCard {
            UpdateRow(updater: AppUpdater.shared)
        }
    }

    // MARK: - Helpers

    static func nativeName(_ language: UILanguage) -> String {
        switch language {
        case .en: return "English"
        case .ru: return "Русский"
        case .zhHans: return "简体中文"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .de: return "Deutsch"
        case .fr: return "Français"
        case .es: return "Español"
        case .ptBR: return "Português (Brasil)"
        case .uk: return "Українська"
        }
    }

    static func relaunch() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"$0\"", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    static func confirmRemoveAll(_ model: SettingsModel) {
        let alert = NSAlert()
        alert.messageText = L.removeAllConfirmTitle
        alert.informativeText = L.removeAllFooter
        alert.alertStyle = .critical
        alert.addButton(withTitle: L.removeAll)
        alert.addButton(withTitle: L.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for agent in AgentKind.allCases where HookInstaller.isInstalled(agent: agent) {
            model.setAgent(agent, enabled: false)
        }
        model.lidGuard.uninstall()
        try? FileManager.default.removeItem(at: BridgePaths.directory())
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        NSApp.terminate(nil)
    }
}

extension AppSettings {
    /// The language this launch is actually using, as a setting value.
    static var launchLanguageChoice: UILanguage? {
        UserDefaults.standard.string(forKey: "languageAtLaunch").flatMap(UILanguage.init(rawValue:))
    }
}

struct LoadRow: View {
    let title: String
    let value: String
    let fraction: Double
    var warn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(value).font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            LimitMeter(fraction: fraction, tint: warn ? .orange : Color(red: 0.55, green: 0.9, blue: 0.55))
        }
    }
}

/// A dark rounded card with an optional small caps title and footnote.
struct PanelCard<Content: View>: View {
    private let title: String?
    private let header: AnyView?
    private let footer: AnyView?
    private let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.header = nil
        self.footer = nil
        self.content = content()
    }

    init<Header: View>(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.title = nil
        self.header = AnyView(header())
        self.footer = nil
        self.content = content()
    }

    init<Footer: View>(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = nil
        self.header = nil
        self.footer = AnyView(footer())
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal, 4)
            }
            if let header {
                header
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                    .textCase(.uppercase)
                    .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
            if let footer {
                footer.padding(.horizontal, 4)
            }
        }
    }
}

struct PillButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

/// The panel that drops from the menu bar icon.
final class TrayPanelController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let model: SettingsModel
    private weak var button: NSStatusBarButton?

    init(model: SettingsModel, button: NSStatusBarButton?, onFullDenny: @escaping () -> Void) {
        self.model = model
        self.button = button
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: SettingsView(
            model: model,
            onFullDenny: onFullDenny,
            onQuit: { NSApp.terminate(nil) }
        ))
    }

    var isShown: Bool { popover.isShown }

    func toggle() {
        if popover.isShown { popover.performClose(nil) } else { show() }
    }

    func show(section: SettingsSection? = nil) {
        guard let button else { return }
        model.refresh()
        if let section { model.section = section }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

/// "Check for updates" in About, and the update itself.
struct UpdateRow: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch updater.state {
            case .idle:
                Button(L.updateCheck) { updater.check() }
            case .checking, .installing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(updater.state == .checking ? L.updateChecking : L.updateInstalling).font(.callout)
                }
            case .upToDate:
                Text(L.updateUpToDate).font(.callout).foregroundColor(.secondary)
                Button(L.updateCheck) { updater.check() }
            case .available(let release):
                Text(L.updateAvailable(release.version)).font(.callout.weight(.semibold))
                Button(L.updateInstall) { updater.install(release) }
                    .buttonStyle(.borderedProminent)
            case .homebrew(let release):
                Text(L.updateAvailable(release.version)).font(.callout.weight(.semibold))
                Text(L.updateHomebrew).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
            case .failed(let message):
                Text(message).font(.callout).foregroundColor(.orange)
                Button(L.updateCheck) { updater.check() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
