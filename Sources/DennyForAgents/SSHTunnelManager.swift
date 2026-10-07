import AgentCore
import AppKit
import Foundation
import Network

/// Keeps one `ssh -N -R` per added server, so hooks on the server reach Denny
/// without Termius or a manual tunnel. Reconnects on its own: when ssh exits,
/// after the Mac wakes up and when the network changes (Wi-Fi, VPN). A fresh
/// report is fetched over the same connection every few minutes, so limits
/// stay current even while no agent is working.
final class SSHTunnelManager {
    enum State: Equatable {
        case connecting
        case connected(remotePort: UInt16, since: Date)
        case failed(SSHLink.Failure, retryAt: Date)
    }

    var onReport: ((UsageReport) -> Void)?
    /// A connected server told its name (on connect and every few minutes):
    /// the app wakes its worker if jobs are waiting for it. Main thread.
    var onHostConnected: ((String) -> Void)?
    /// For the settings window; main thread.
    var onChange: () -> Void = {}
    private(set) var servers: [SSHServer] = SSHTunnelManager.load()
    private(set) var states: [String: State] = [:]
    /// The name a server reports itself by (its hostname) -> our server id.
    private var hostNames: [String: String] = [:]
    private var tunnels: [String: Tunnel] = [:]
    private let localSetup: () -> (port: UInt16, token: String)?
    private var wakeObserver: NSObjectProtocol?
    private let pathMonitor = NWPathMonitor()
    private var lastPath: String?
    private var reportTimer: Timer?
    static let reportInterval: TimeInterval = 5 * 60
    private let ssh = URL(fileURLWithPath: "/usr/bin/ssh")

    private final class Tunnel {
        let server: SSHServer
        var process: Process?
        var portIndex = 0
        var attempt = 0
        var retry: DispatchWorkItem?
        var stderr = Data()
        var stopped = false
        init(server: SSHServer) { self.server = server }
    }

    init(localSetup: @escaping () -> (port: UInt16, token: String)?) {
        self.localSetup = localSetup
    }

    func start() {
        for server in servers { open(server) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The old connection is almost certainly dead; don't wait 45 s to find out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.reconnectAll() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = path.status == .satisfied ? path.availableInterfaces.map(\.name).joined(separator: ",") : "offline"
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.lastPath = signature }
                if self.lastPath != nil, self.lastPath != signature, signature != "offline" { self.reconnectAll() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "denny.ssh.path"))
        reportTimer = Timer.scheduledTimer(withTimeInterval: Self.reportInterval, repeats: true) { [weak self] _ in
            self?.fetchReports()
        }
    }

    func stopAll() {
        for tunnel in tunnels.values { close(tunnel) }
        tunnels.removeAll()
    }

    // MARK: - servers

    /// Adds and connects; false for an address that isn't `user@host` or an alias.
    @discardableResult
    func add(destination: String) -> Bool {
        let value = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SSHLink.isValidDestination(value), !servers.contains(where: { $0.destination == value }) else { return false }
        let server = SSHServer(destination: value)
        servers.append(server)
        save()
        open(server)
        return true
    }

    func remove(id: String, uninstallHooks: Bool) {
        guard let server = servers.first(where: { $0.id == id }) else { return }
        if uninstallHooks {
            run(SSHLink.uninstallCommand, on: server) { _, _ in }
        }
        if let tunnel = tunnels.removeValue(forKey: id) { close(tunnel) }
        servers.removeAll { $0.id == id }
        states[id] = nil
        save()
        onChange()
    }

    /// "Connect": puts the bundled hook on the server and wires Claude Code and
    /// Codex there to it. `done` gets nil on success or what went wrong.
    func installHooks(id: String, done: @escaping (String?) -> Void) {
        guard let server = servers.first(where: { $0.id == id }),
              let setup = localSetup(),
              let script = UsageCollector.script, let hook = try? Data(contentsOf: script) else {
            done(L.sshInstallFailed(""))
            return
        }
        let port = currentRemotePort(id) ?? SSHLink.remotePorts[0]
        run(SSHLink.installCommand(port: port, token: setup.token), on: server, input: hook) { status, output in
            done(status == 0 ? nil : L.sshInstallFailed(Self.describe(SSHLink.classify(stderr: output))))
        }
    }

    /// Jobs wait for `host` (as it names itself): start its worker over our
    /// connection, so they don't wait for the next agent activity there.
    func wakeWorker(host: String) {
        guard let id = hostNames[host], currentRemotePort(id) != nil,
              let server = servers.first(where: { $0.id == id }) else { return }
        run(SSHLink.startWorkerCommand, on: server) { _, _ in }
    }

    func reconnectAll() {
        for server in servers {
            if let tunnel = tunnels.removeValue(forKey: server.id) { close(tunnel) }
            open(server)
        }
    }

    // MARK: - tunnel

    private func open(_ server: SSHServer) {
        let tunnel = Tunnel(server: server)
        tunnels[server.id] = tunnel
        launch(tunnel)
    }

    private func close(_ tunnel: Tunnel) {
        tunnel.stopped = true
        tunnel.retry?.cancel()
        if let process = tunnel.process, process.isRunning { process.terminate() }
        tunnel.process = nil
    }

    private func launch(_ tunnel: Tunnel) {
        guard !tunnel.stopped else { return }
        guard let setup = localSetup() else {
            // Denny's own port isn't listening (yet); try again shortly.
            scheduleRetry(tunnel, failure: .other(L.remoteUnavailable))
            return
        }
        let remotePort = SSHLink.remotePorts[tunnel.portIndex % SSHLink.remotePorts.count]
        let process = Process()
        process.executableURL = ssh
        process.arguments = SSHLink.tunnelArguments(destination: tunnel.server.destination, remotePort: remotePort,
                                                    localPort: setup.port, controlPath: Self.controlPath)
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        tunnel.stderr = Data()
        errors.fileHandleForReading.readabilityHandler = { [weak tunnel] handle in
            let chunk = handle.availableData
            DispatchQueue.main.async {
                guard let tunnel, tunnel.stderr.count < 16_384 else { return }
                tunnel.stderr.append(chunk)
            }
        }
        let startedAt = Date()
        process.terminationHandler = { [weak self, weak tunnel] finished in
            errors.fileHandleForReading.readabilityHandler = nil
            let rest = errors.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                guard let self, let tunnel, tunnel.process === finished else { return }
                tunnel.stderr.append(rest)
                tunnel.process = nil
                guard !tunnel.stopped else { return }
                let failure = SSHLink.classify(stderr: String(decoding: tunnel.stderr, as: UTF8.self))
                if failure == .portBusy {
                    tunnel.portIndex += 1
                } else if Date().timeIntervalSince(startedAt) > 120 {
                    tunnel.attempt = 0  // it was up for a while: a fresh drop, reconnect quickly
                }
                self.scheduleRetry(tunnel, failure: failure)
            }
        }
        tunnel.process = process
        states[tunnel.server.id] = .connecting
        onChange()
        do {
            try process.run()
        } catch {
            tunnel.process = nil
            scheduleRetry(tunnel, failure: .other(error.localizedDescription))
            return
        }
        // ExitOnForwardFailure makes a failed forward exit within seconds; still
        // running after that means the tunnel is up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak tunnel] in
            guard let self, let tunnel, tunnel.process === process, process.isRunning else { return }
            tunnel.attempt = 0
            self.states[tunnel.server.id] = .connected(remotePort: remotePort, since: Date())
            self.onChange()
            // The hook on the server must knock on the port that actually worked
            // (harmless before the hook is installed: there's nothing to update).
            self.run(SSHLink.setPortCommand(remotePort), on: tunnel.server) { _, _ in }
            self.fetchReport(tunnel.server)
        }
    }

    private func scheduleRetry(_ tunnel: Tunnel, failure: SSHLink.Failure) {
        let delay = SSHLink.retryDelay(attempt: tunnel.attempt)
        tunnel.attempt += 1
        states[tunnel.server.id] = .failed(failure, retryAt: Date().addingTimeInterval(delay))
        onChange()
        let work = DispatchWorkItem { [weak self, weak tunnel] in
            guard let self, let tunnel else { return }
            self.launch(tunnel)
        }
        tunnel.retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func currentRemotePort(_ id: String) -> UInt16? {
        if case .connected(let port, _) = states[id] { return port }
        return nil
    }

    // MARK: - reports and commands

    private func fetchReports() {
        for server in servers where currentRemotePort(server.id) != nil { fetchReport(server) }
    }

    private func fetchReport(_ server: SSHServer) {
        run(SSHLink.reportCommand, on: server) { [weak self] status, output in
            guard status == 0, let line = output.split(whereSeparator: \.isNewline).last,
                  let report = try? JSONDecoder().decode(UsageReport.self, from: Data(line.utf8)) else { return }
            self?.hostNames[report.host] = server.id
            self?.onReport?(report)
            self?.onHostConnected?(report.host)
        }
    }

    /// Runs one command on the server; `done(status, stdout or stderr)` on main.
    private func run(_ command: String, on server: SSHServer, input: Data? = nil,
                     done: @escaping (Int32, String) -> Void) {
        let process = Process()
        process.executableURL = ssh
        process.arguments = SSHLink.commandArguments(destination: server.destination, controlPath: Self.controlPath,
                                                     command: command)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        DispatchQueue.global(qos: .utility).async {
            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { done(-1, error.localizedDescription) }
                return
            }
            if let input {
                stdin.fileHandleForWriting.write(input)
                try? stdin.fileHandleForWriting.close()
            }
            // Read both pipes before waiting, or a big report could fill a pipe and hang.
            var stderrData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                stderrData = err.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
            group.wait()
            process.waitUntilExit()
            let status = process.terminationStatus
            let text = String(decoding: status == 0 ? stdoutData : stderrData, as: UTF8.self)
            DispatchQueue.main.async { done(status, text) }
        }
    }

    static func describe(_ failure: SSHLink.Failure) -> String {
        switch failure {
        case .needsKey: return L.sshNeedsKey
        case .hostKeyChanged: return L.sshHostKeyChanged
        case .unreachable: return L.sshUnreachable
        case .portBusy: return L.sshPortBusy
        case .noPython: return L.sshNoPython
        case .other(let text): return text.isEmpty ? L.sshDropped : text
        }
    }

    // MARK: - storage

    /// Short on purpose: a Unix socket path must stay under 104 bytes.
    private static var controlPath: String { BridgePaths.directory().appendingPathComponent("ssh-%C").path }
    private static var fileURL: URL { BridgePaths.directory().appendingPathComponent("ssh-servers.json") }

    private static func load() -> [SSHServer] {
        guard let data = try? Data(contentsOf: fileURL),
              let servers = try? JSONDecoder().decode([SSHServer].self, from: data) else { return [] }
        return servers.filter { SSHLink.isValidDestination($0.destination) }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: BridgePaths.directory(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(servers) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
