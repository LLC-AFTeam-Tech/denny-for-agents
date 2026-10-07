import AgentCore
import Foundation

/// Listens on ~/.denny-for-agents/agents.sock. Each hook call is one short
/// connection; approval requests keep theirs open until the user answers.
final class AgentBridgeServer {
    var onEvent: ((HookEvent, String?) -> Void)?
    var onReport: ((UsageReport) -> Void)?
    /// Files waiting for the server that sent this event.
    var onFilesRequest: ((HookEvent) -> [FileOutbox.Item])?
    /// A server worker asks for jobs (and hands in results).
    var onJobsRequest: ((String, [RemoteJobResult], [String]?) -> [RemoteJob])?
    /// A finished task's Stop hook offers to wait for a reply from the phone.
    /// Main thread; called before onEvent. False: release it right away.
    var onReplyOffered: ((HookEvent, String) -> Bool)?

    private var listener: UnixSocket?
    private var remoteListener: UnixSocket?
    private var waiting: [String: UnixSocket] = [:]
    private var waitingReplies: [String: UnixSocket] = [:]
    private var stopped = false
    private(set) var remoteToken: String?
    private(set) var remotePort: UInt16 = RemoteBridge.defaultPort
    var remoteListening: Bool { remoteListener != nil }

    func start() -> Bool {
        guard let listener = UnixSocket.listen(path: BridgePaths.socket().path) else { return false }
        self.listener = listener
        Thread.detachNewThread { [weak self] in
            self?.acceptLoop(listener, requiredToken: nil)
        }
        startRemote()
        return true
    }

    /// Loopback TCP for hooks on SSH servers (through a forwarded port).
    private func startRemote() {
        guard let token = RemoteBridge.loadOrCreateToken(),
              let remote = UnixSocket.listenLoopback(port: remotePort) else { return }
        remoteToken = token
        remoteListener = remote
        Thread.detachNewThread { [weak self] in
            self?.acceptLoop(remote, requiredToken: token)
        }
    }

    /// Main thread only.
    func answer(id: String, decision: ApprovalDecision) {
        guard let client = waiting.removeValue(forKey: id) else { return }
        if let line = try? BridgeCodec.encodeLine(BridgeResponse(id: id, decision: decision)) {
            client.write(line)
        }
        client.close()
    }

    /// Main thread only. Ends a waiting Stop hook: with the user's reply the
    /// agent goes on, with nil it just finishes. False if the hook is gone.
    @discardableResult
    func reply(id: String, text: String?) -> Bool {
        guard let client = waitingReplies.removeValue(forKey: id) else { return false }
        defer { client.close() }
        if text != nil, client.peerHasClosed { return false }
        guard let line = try? BridgeCodec.encodeLine(BridgeResponse(id: id, decision: .ask, reply: text)) else { return false }
        return client.write(line)
    }

    /// Main thread only. Whether that Stop hook is still there to hear a reply.
    func isWaitingForReply(id: String) -> Bool {
        guard let client = waitingReplies[id] else { return false }
        return !client.peerHasClosed
    }

    /// Main thread only. Waiting agents get their terminal prompt back.
    func stop() {
        stopped = true
        for id in Array(waiting.keys) {
            answer(id: id, decision: .ask)
        }
        for id in Array(waitingReplies.keys) {
            reply(id: id, text: nil)
        }
        listener?.close()
        remoteListener?.close()
        unlink(BridgePaths.socket().path)
    }

    private func acceptLoop(_ listener: UnixSocket, requiredToken: String?) {
        while !stopped {
            guard let client = listener.accept() else {
                usleep(50_000)
                continue
            }
            Thread.detachNewThread { [weak self] in
                self?.serve(client, requiredToken: requiredToken)
            }
        }
    }

    private func serve(_ client: UnixSocket, requiredToken: String?) {
        client.setReceiveTimeout(seconds: 5)
        guard let line = client.readLine(),
              let request = try? BridgeCodec.decode(BridgeRequest.self, line: line) else { return }
        if let requiredToken, !RemoteBridge.tokensMatch(request.token, requiredToken) { return }
        if request.wantsJobs == true {
            let host = request.event.host ?? "server"
            let jobs: [RemoteJob] = DispatchQueue.main.sync {
                guard !self.stopped else { return [] }
                return self.onJobsRequest?(host, request.jobResults ?? [], request.jobsReceived) ?? []
            }
            if let line = try? BridgeCodec.encodeLine(JobBatch(id: request.id, jobs: jobs)) {
                client.write(line)
            }
            return
        }
        if request.wantsFiles == true {
            let items: [FileOutbox.Item] = DispatchQueue.main.sync {
                guard !self.stopped else { return [] }
                self.onEvent?(request.event, nil)
                return self.onFilesRequest?(request.event) ?? []
            }
            var delivery = FileDelivery(id: request.id, items: items)
            delivery.safetyNet = SafetyNetSettings.load()
            if let line = try? BridgeCodec.encodeLine(delivery) {
                client.write(line)
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            if let report = request.report {
                self.onReport?(report)
                // A report travels with a placeholder event; it isn't a session.
                if request.event.name == .other { return }
            }
            if request.wantsDecision {
                self.waiting[request.id] = client
                self.onEvent?(request.event, request.id)
            } else if request.wantsReply == true {
                self.waitingReplies[request.id] = client
                if self.onReplyOffered?(request.event, request.id) != true { self.reply(id: request.id, text: nil) }
                self.onEvent?(request.event, nil)
            } else {
                self.onEvent?(request.event, nil)
            }
        }
    }
}
