import Foundation

/// A server Denny keeps an SSH connection to by itself: the forwarded port for
/// hooks (approvals, jobs, files, reports) without Termius or a manual
/// `ssh -R`, reconnected after sleep, a network change or a VPN reconnect.
/// Uses the Mac's own `ssh`, so `~/.ssh/config`, keys and the agent just work.
public struct SSHServer: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// Exactly what the user types after `ssh`: `root@1.2.3.4`, `me@host:2222`
    /// is NOT accepted (use ~/.ssh/config for ports), or an alias from ~/.ssh/config.
    public var destination: String

    public init(id: String = UUID().uuidString, destination: String) {
        self.id = id
        self.destination = destination
    }
}

public enum SSHLink {
    /// Remote ports tried in order: a dead session can keep the first one
    /// busy on the server for a while after the network drops.
    public static let remotePorts: [UInt16] = Array(47321...47325)

    /// `user@host` or a ~/.ssh/config alias. Never starting with "-" (it would
    /// be read as an ssh option), no spaces or shell-ish characters.
    public static func isValidDestination(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 255, !value.hasPrefix("-") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@.-_"))
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return value.filter { $0 == "@" }.count <= 1 && !value.hasSuffix("@")
    }

    /// Options shared by every call, so they reuse one connection: the tunnel
    /// is the master, short commands ride on it.
    public static func commonOptions(controlPath: String) -> [String] {
        [
            "-o", "BatchMode=yes",                    // never stop on a password prompt
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",           // notice a dead link within ~45 s
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new", // first connect to a new host is fine, a changed key is not
            "-o", "ControlPath=\(controlPath)",
        ]
    }

    /// The long-lived tunnel: server 127.0.0.1:remotePort -> this Mac 127.0.0.1:localPort.
    public static func tunnelArguments(destination: String, remotePort: UInt16, localPort: UInt16,
                                       controlPath: String) -> [String] {
        commonOptions(controlPath: controlPath) + [
            "-o", "ControlMaster=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-N", "-T",
            "-R", "127.0.0.1:\(remotePort):127.0.0.1:\(localPort)",
            "--", destination,
        ]
    }

    /// A one-off command on the server, sharing the tunnel's connection when it's up.
    public static func commandArguments(destination: String, controlPath: String, command: String) -> [String] {
        commonOptions(controlPath: controlPath) + ["-o", "ControlMaster=auto", "-o", "ControlPersist=60",
                                                   "-T", "--", destination, command]
    }

    /// Copies the hook (sent on stdin) into place and connects the agents.
    /// Port and token are numbers and hex, so the command needs no quoting.
    public static func installCommand(port: UInt16, token: String) -> String {
        precondition(token.allSatisfy(\.isHexDigit))
        let dir = "~/.denny-for-agents"
        return "mkdir -p \(dir) && chmod 700 \(dir)"
            + " && cat > \(dir)/denny-hook.py.part && chmod 755 \(dir)/denny-hook.py.part"
            + " && mv \(dir)/denny-hook.py.part \(dir)/denny-hook.py"
            + " && python3 \(dir)/denny-hook.py --install --port \(port) --token \(token)"
    }

    public static func setPortCommand(_ port: UInt16) -> String {
        "python3 ~/.denny-for-agents/denny-hook.py --set-port \(port)"
    }

    public static let reportCommand = "python3 ~/.denny-for-agents/denny-hook.py --report"
    public static let uninstallCommand = "python3 ~/.denny-for-agents/denny-hook.py --uninstall"

    /// Why ssh gave up, from its stderr, in terms the settings can explain.
    public enum Failure: Equatable, Sendable {
        /// No key the server accepts (BatchMode refuses to ask for a password).
        case needsKey
        case hostKeyChanged
        case unreachable
        case portBusy
        case noPython
        case other(String)
    }

    public static func classify(stderr: String) -> Failure {
        let text = stderr.lowercased()
        if text.contains("remote port forwarding failed") || text.contains("address already in use") { return .portBusy }
        if text.contains("remote host identification has changed") || text.contains("host key verification failed") {
            return .hostKeyChanged
        }
        if text.contains("permission denied") || text.contains("too many authentication failures") { return .needsKey }
        if text.contains("could not resolve hostname") || text.contains("connection timed out")
            || text.contains("connection refused") || text.contains("network is unreachable")
            || text.contains("no route to host") || text.contains("operation timed out") {
            return .unreachable
        }
        if text.contains("python3: command not found") || text.contains("python3: not found") { return .noPython }
        let last = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return .other(String(last.trimmingCharacters(in: .whitespaces).prefix(200)))
    }

    /// Waits between reconnects: quick at first, then calmer, never silent for long.
    public static func retryDelay(attempt: Int) -> TimeInterval {
        [2, 5, 10, 20, 30, 60][min(max(attempt, 0), 5)]
    }

    /// The commands to put a key on a server, for the "needs a key" hint.
    public static func keySetupCommands(destination: String) -> String {
        "[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519\nssh-copy-id \(destination)"
    }
}
