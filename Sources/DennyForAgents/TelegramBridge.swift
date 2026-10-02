import AgentCore
import AppKit
import Security

/// Approvals from the phone through the user's own Telegram bot. The token
/// lives in the Keychain; only the chat that sent the pairing code is obeyed.
final class TelegramBridge: ObservableObject {
    struct Settings: Codable, Equatable {
        var chatId: Int64?
        var chatName: String?
        /// The topic the code was sent in: everything goes there.
        var threadId: Int64?
        /// Who sent the code: in a group only they may press the buttons.
        var userId: Int64?
        var botName: String?
        var alwaysSend = false
        var sendFinished = true
    }

    static let shared = TelegramBridge()
    static let awayAfter: TimeInterval = 120

    @Published private(set) var settings: Settings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "telegram") }
        }
    }
    @Published private(set) var pairingCode: String?
    @Published private(set) var error: String?

    /// Main thread: a button was pressed on the phone.
    var onDecision: ((String, ApprovalDecision) -> Void)?

    private var token: String?
    private var polling = false
    private var offset: Int64 = 0
    /// approval id -> Telegram message id
    private var messages: [String: Int64] = [:]
    private let lock = NSLock()

    private init() {
        settings = UserDefaults.standard.data(forKey: "telegram")
            .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        token = Keychain.read()
    }

    var isConnected: Bool { token != nil && settings.chatId != nil }

    func start() {
        if token != nil { startPolling() }
    }

    // MARK: - Setup

    /// Checks the token with getMe, stores it and waits for the pairing code.
    func connect(token raw: String) {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        error = nil
        call("getMe", token: token, params: [:]) { [weak self] result in
            guard let self else { return }
            guard let name = (result as? [String: Any])?["username"] as? String else {
                self.error = L.phoneBadToken
                return
            }
            Keychain.save(token)
            self.token = token
            self.settings = Settings(botName: name)
            self.pairingCode = String(format: "%06d", Int.random(in: 0...999_999))
            self.startPolling()
        }
    }

    func disconnect() {
        Keychain.delete()
        token = nil
        polling = false
        pairingCode = nil
        settings = Settings()
    }

    func setAlwaysSend(_ value: Bool) { settings.alwaysSend = value }
    func setSendFinished(_ value: Bool) { settings.sendFinished = value }

    /// The bot's chat with the pairing code already typed in.
    var botLink: URL? {
        guard let bot = settings.botName, let code = pairingCode else { return nil }
        return URL(string: "https://t.me/\(bot)?start=\(code)")
    }

    // MARK: - Sending

    /// Away from the Mac: no mouse or keyboard for a couple of minutes.
    var shouldForward: Bool {
        guard isConnected else { return false }
        if settings.alwaysSend { return true }
        let anyEvent = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent) >= Self.awayAfter
    }

    func sendApproval(id: String, text: String) {
        guard shouldForward, let chat = settings.chatId else { return }
        let keyboard: [String: Any] = ["inline_keyboard": [[
            ["text": L.phoneAllow, "callback_data": "a:" + id],
            ["text": L.phoneDeny, "callback_data": "d:" + id]
        ]]]
        call("sendMessage", params: target(chat).merging(["text": text, "reply_markup": keyboard]) { $1 }) { [weak self] result in
            guard let messageId = (result as? [String: Any])?["message_id"] as? Int64 else { return }
            self?.locked { self?.messages[id] = messageId }
        }
    }

    /// The request was answered (anywhere) or timed out: replace the buttons with the outcome.
    func finish(id: String, text: String) {
        guard let chat = settings.chatId, let messageId = locked({ messages.removeValue(forKey: id) }) else { return }
        call("editMessageReplyMarkup", params: ["chat_id": chat, "message_id": messageId, "reply_markup": ["inline_keyboard": [Any]()]])
        call("sendMessage", params: target(chat).merging(["text": text, "reply_to_message_id": messageId]) { $1 })
    }

    func send(_ text: String, force: Bool = false) {
        guard force ? isConnected : shouldForward, let chat = settings.chatId else { return }
        call("sendMessage", params: target(chat).merging(["text": text]) { $1 })
    }

    /// The chat, plus the topic when the code came from one.
    private func target(_ chat: Int64) -> [String: Any] {
        var params: [String: Any] = ["chat_id": chat]
        if let thread = settings.threadId { params["message_thread_id"] = thread }
        return params
    }

    // MARK: - Receiving

    private func startPolling() {
        guard !polling else { return }
        polling = true
        Thread.detachNewThread { [weak self] in
            while let self, self.polling, let token = self.token {
                guard let updates = self.getUpdates(token: token) else {
                    Thread.sleep(forTimeInterval: 5)
                    continue
                }
                for update in updates { self.handle(update) }
            }
        }
    }

    private func getUpdates(token: String) -> [[String: Any]]? {
        var result: [[String: Any]]?
        let done = DispatchSemaphore(value: 0)
        call("getUpdates", token: token, params: ["offset": offset, "timeout": 25,
                                                  "allowed_updates": ["message", "callback_query"]],
             timeout: 35, onMain: false) { value in
            result = value as? [[String: Any]]
            done.signal()
        }
        done.wait()
        if let last = result?.last?["update_id"] as? Int64 { offset = last + 1 }
        return result
    }

    private func handle(_ update: [String: Any]) {
        if let message = update["message"] as? [String: Any],
           let chat = message["chat"] as? [String: Any], let chatId = chat["id"] as? Int64,
           let text = message["text"] as? String {
            let from = message["from"] as? [String: Any]
            let name = from?["first_name"] as? String ?? chat["title"] as? String
            let thread = message["message_thread_id"] as? Int64
            DispatchQueue.main.async {
                self.pair(chatId: chatId, threadId: thread, userId: from?["id"] as? Int64, name: name, text: text)
            }
        }
        guard let query = update["callback_query"] as? [String: Any], let queryId = query["id"] as? String else { return }
        let message = query["message"] as? [String: Any]
        let chatId = (message?["chat"] as? [String: Any])?["id"] as? Int64
        let fromId = (query["from"] as? [String: Any])?["id"] as? Int64
        let data = query["data"] as? String ?? ""
        DispatchQueue.main.async {
            let allowedUser = self.settings.userId == nil || fromId == self.settings.userId
            guard chatId != nil, chatId == self.settings.chatId, allowedUser, data.count > 2 else {
                self.call("answerCallbackQuery", params: ["callback_query_id": queryId])
                return
            }
            let decision: ApprovalDecision = data.hasPrefix("a:") ? .allow : .deny
            let id = String(data.dropFirst(2))
            let known = self.locked { self.messages[id] != nil }
            self.call("answerCallbackQuery", params: ["callback_query_id": queryId,
                                                      "text": known ? (decision == .allow ? L.phoneAllowed : L.phoneDenied) : L.phoneExpired])
            if known { self.onDecision?(id, decision) }
        }
    }

    /// The first message carrying the code binds the bot to that chat, that
    /// topic (if any) and that person.
    private func pair(chatId: Int64, threadId: Int64?, userId: Int64?, name: String?, text: String) {
        guard settings.chatId == nil, let code = pairingCode, text.contains(code) else { return }
        settings.chatId = chatId
        settings.threadId = threadId
        settings.userId = userId
        settings.chatName = name
        pairingCode = nil
        send(L.phonePaired, force: true)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - HTTP

    private func call(_ method: String, token: String? = nil, params: [String: Any], timeout: TimeInterval = 20,
                      onMain: Bool = true, completion: ((Any?) -> Void)? = nil) {
        guard let token = token ?? self.token,
              let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)"),
              let body = try? JSONSerialization.data(withJSONObject: params) else {
            completion?(nil)
            return
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let result = json?["ok"] as? Bool == true ? json?["result"] : nil
            if onMain {
                DispatchQueue.main.async { completion?(result) }
            } else {
                completion?(result)
            }
        }.resume()
    }

    // MARK: - Keychain

    private enum Keychain {
        static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                           kSecAttrService as String: "tech.afteam.denny-for-agents.telegram",
                                           kSecAttrAccount as String: "bot-token"]

        static func save(_ token: String) {
            delete()
            var item = query
            item[kSecValueData as String] = Data(token.utf8)
            SecItemAdd(item as CFDictionary, nil)
        }

        static func read() -> String? {
            var item = query
            item[kSecReturnData as String] = true
            item[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func delete() {
            SecItemDelete(query as CFDictionary)
        }
    }
}
