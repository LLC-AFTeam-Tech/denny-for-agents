import Foundation
import XCTest
@testable import AgentCore

final class HookEventTests: XCTestCase {
    func testParsesClaudePreToolUse() throws {
        let json = """
        {"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/Users/t/projects/shop",
         "tool_name":"Bash","tool_input":{"command":"npm test"},"tool_use_id":"x"}
        """
        let event = try HookEvent.parse(Data(json.utf8), agent: .claude)
        XCTAssertEqual(event.name, .preToolUse)
        XCTAssertEqual(event.sessionId, "s1")
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertEqual(event.toolInput?["command"], .string("npm test"))
    }

    func testUnknownEventBecomesOther() throws {
        let json = #"{"session_id":"s1","hook_event_name":"PreCompact"}"#
        XCTAssertEqual(try HookEvent.parse(Data(json.utf8), agent: .codex).name, .other)
    }

    func testRejectsGarbageAndMissingSession() {
        XCTAssertThrowsError(try HookEvent.parse(Data("not json".utf8), agent: .claude))
        XCTAssertThrowsError(try HookEvent.parse(Data(#"{"hook_event_name":"Stop"}"#.utf8), agent: .claude))
    }

    func testClipsLongText() throws {
        let long = String(repeating: "a", count: HookEvent.maxTextLength + 50)
        let json = #"{"session_id":"s","hook_event_name":"UserPromptSubmit","prompt":"\#(long)"}"#
        let event = try HookEvent.parse(Data(json.utf8), agent: .claude)
        XCTAssertEqual(event.prompt?.count, HookEvent.maxTextLength + 1)
    }
}

final class StepDescriberTests: XCTestCase {
    private func describe(_ tool: String, _ input: [String: JSONValue], _ language: UILanguage = .en) -> String {
        StepDescriber.describe(toolName: tool, toolInput: input, language: language)
    }

    func testCommonTools() {
        XCTAssertEqual(describe("Bash", ["command": .string("npm test\necho done")]), "Runs npm test")
        XCTAssertEqual(describe("Read", ["file_path": .string("/a/b/Package.swift")]), "Reads Package.swift")
        XCTAssertEqual(describe("Edit", ["file_path": .string("/a/App.swift")], .ru), "Правит App.swift")
        XCTAssertEqual(describe("Grep", ["pattern": .string("TODO")]), "Searches “TODO”")
        XCTAssertEqual(describe("mcp__memory__read_file", [:]), "Uses memory: read_file")
        XCTAssertEqual(describe("Mystery", [:]), "Uses Mystery")
    }

    func testCodexShellArrayAndPatch() {
        let shell: [String: JSONValue] = ["command": .array([.string("bash"), .string("-lc"), .string("cargo build")])]
        XCTAssertEqual(describe("Bash", shell), "Runs cargo build")
        let patch: [String: JSONValue] = ["input": .string("*** Begin Patch\n*** Update File: src/main.rs\n@@")]
        XCTAssertEqual(describe("apply_patch", patch), "Edits main.rs")
    }

    func testLongCommandIsShortened() {
        let command = String(repeating: "x", count: 100)
        XCTAssertEqual(describe("Bash", ["command": .string(command)]).count, "Runs ".count + StepDescriber.commandLimit + 1)
    }
}

final class AgentStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func event(_ name: HookEventName, agent: AgentKind = .claude, session: String = "s1",
                       tool: String? = nil, input: [String: JSONValue]? = nil,
                       notificationType: String? = nil, last: String? = nil) -> HookEvent {
        HookEvent(agent: agent, name: name, sessionId: session, cwd: "/Users/t/shop",
                  toolName: tool, toolInput: input, notificationType: notificationType, lastAssistantMessage: last)
    }

    func testWorkingFlowAndCelebration() {
        var store = AgentStore(language: .en)
        store.apply(event(.sessionStart), now: t0)
        XCTAssertEqual(store.mood, .idle)
        store.apply(event(.userPromptSubmit), now: t0)
        store.apply(event(.preToolUse, tool: "Read", input: ["file_path": .string("/x/a.swift")]), now: t0)
        let session = store.sessions["claude:s1"]
        XCTAssertEqual(session?.status, .working)
        XCTAssertEqual(session?.currentStep, "Reads a.swift")
        XCTAssertEqual(session?.projectName, "shop")
        XCTAssertEqual(store.mood, .working)

        let effects = store.apply(event(.stop, last: "All done"), now: t0)
        XCTAssertEqual(effects, [.celebrate(sessionKey: "claude:s1", duration: 0)])
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .finished)
        XCTAssertEqual(store.sessions["claude:s1"]?.lastMessage, "All done")
    }

    func testApprovalLifecycle() {
        var store = AgentStore(language: .en)
        let effects = store.apply(event(.permissionRequest, agent: .codex, tool: "Bash",
                                        input: ["command": .string("rm -rf build")]), requestId: "r1", now: t0)
        XCTAssertEqual(effects, [.needsAttention(approvalId: "r1")])
        XCTAssertEqual(store.mood, .needsYou)
        XCTAssertEqual(store.approvals.first?.summary, "Runs rm -rf build")
        XCTAssertEqual(store.approvals.first?.detail, "rm -rf build")
        XCTAssertEqual(store.sessions["codex:s1"]?.status, .waitingApproval)

        XCTAssertEqual(store.resolveApproval(id: "r1")?.id, "r1")
        XCTAssertNil(store.resolveApproval(id: "r1"))
        XCTAssertEqual(store.sessions["codex:s1"]?.status, .working)
        XCTAssertEqual(store.mood, .working)
    }

    func testPermissionRequestWithoutIdIsIgnored() {
        var store = AgentStore(language: .en)
        store.apply(event(.permissionRequest, tool: "Bash"), now: t0)
        XCTAssertTrue(store.approvals.isEmpty)
    }

    func testStopClearsApprovalsAndSessionEndRemovesSession() {
        var store = AgentStore(language: .en)
        store.apply(event(.permissionRequest, tool: "Bash"), requestId: "r1", now: t0)
        store.apply(event(.stop), now: t0)
        XCTAssertTrue(store.approvals.isEmpty)
        store.apply(event(.sessionEnd), now: t0)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testIdleNotificationMeansYourTurn() {
        var store = AgentStore(language: .en)
        store.apply(event(.notification, notificationType: "permission_prompt"), now: t0)
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .idle)
        store.apply(event(.notification, notificationType: "idle_prompt"), now: t0)
        XCTAssertEqual(store.sessions["claude:s1"]?.status, .waitingInput)
        XCTAssertEqual(store.mood, .needsYou)
    }

    func testStepsAreCapped() {
        var store = AgentStore(language: .en)
        for index in 0..<8 {
            store.apply(event(.preToolUse, tool: "Read", input: ["file_path": .string("/f\(index)")]), now: t0)
        }
        XCTAssertEqual(store.sessions["claude:s1"]?.recentSteps.count, AgentSession.maxSteps)
        XCTAssertEqual(store.sessions["claude:s1"]?.recentSteps.last, "Reads f7")
    }

    func testUrgentSessionsComeFirst() {
        var store = AgentStore(language: .en)
        store.apply(event(.userPromptSubmit, session: "busy"), now: t0)
        store.apply(event(.permissionRequest, session: "asks", tool: "Bash"), requestId: "r", now: t0)
        store.apply(event(.userPromptSubmit, session: "newest"), now: t0.addingTimeInterval(5))
        XCTAssertEqual(store.orderedSessions.map(\.sessionId), ["asks", "newest", "busy"])
    }

    func testPruneDropsOldFinishedSessions() {
        var store = AgentStore(language: .en)
        store.apply(event(.stop, session: "old"), now: t0)
        store.apply(event(.permissionRequest, session: "waiting", tool: "Bash"), requestId: "r", now: t0)
        store.prune(now: t0.addingTimeInterval(AgentStore.staleLifetime + 1))
        XCTAssertEqual(Set(store.sessions.values.map(\.sessionId)), ["waiting"])
        XCTAssertEqual(store.approvals.count, 1)
    }
}

final class HookOutputTests: XCTestCase {
    func testAllowAndDeny() {
        XCTAssertEqual(
            HookOutput.permissionResponse(.allow, agent: .claude),
            #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#
        )
        XCTAssertEqual(
            HookOutput.permissionResponse(.deny, agent: .codex),
            #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Denied from Denny for Agents"},"hookEventName":"PermissionRequest"}}"#
        )
        XCTAssertNil(HookOutput.permissionResponse(.ask, agent: .claude))
    }
}

final class BridgeTests: XCTestCase {
    func testRequestRoundTrip() throws {
        let event = HookEvent(agent: .codex, name: .permissionRequest, sessionId: "s", toolName: "Bash",
                              toolInput: ["command": .string("ls")])
        let request = BridgeRequest(id: "1", event: event, wantsDecision: true)
        var line = try BridgeCodec.encodeLine(request)
        XCTAssertEqual(line.last, 0x0A)
        line.removeLast()
        XCTAssertEqual(try BridgeCodec.decode(BridgeRequest.self, line: line), request)
    }

    func testSocketRoundTrip() throws {
        let path = NSTemporaryDirectory() + "dfa-\(UUID().uuidString.prefix(8)).sock"
        guard let server = UnixSocket.listen(path: path) else { return XCTFail("listen failed") }
        let accepted = expectation(description: "reply sent")
        DispatchQueue.global().async {
            guard let client = server.accept(), let line = client.readLine(),
                  let request = try? BridgeCodec.decode(BridgeRequest.self, line: line),
                  let reply = try? BridgeCodec.encodeLine(BridgeResponse(id: request.id, decision: .allow)) else { return }
            client.write(reply)
            accepted.fulfill()
        }
        let socket = try XCTUnwrap(UnixSocket.connect(path: path))
        let request = BridgeRequest(id: "abc", event: HookEvent(agent: .claude, name: .permissionRequest, sessionId: "s"),
                                    wantsDecision: true)
        XCTAssertTrue(socket.write(try BridgeCodec.encodeLine(request)))
        socket.setReceiveTimeout(seconds: 5)
        let reply = try XCTUnwrap(socket.readLine())
        XCTAssertEqual(try BridgeCodec.decode(BridgeResponse.self, line: reply), BridgeResponse(id: "abc", decision: .allow))
        wait(for: [accepted], timeout: 5)
        unlink(path)
    }

    func testConnectWithoutServerFailsQuietly() {
        XCTAssertNil(UnixSocket.connect(path: NSTemporaryDirectory() + "nobody-\(UUID().uuidString.prefix(8)).sock"))
    }
}

final class HookInstallerTests: XCTestCase {
    private let hook = "/Users/t/.denny-for-agents/bin/denny-hook"

    func testClaudeMergeKeepsUserHooksAndIsIdempotent() {
        let userHook: [String: Any] = ["matcher": "Bash", "hooks": [["type": "command", "command": "my-check.sh"]]]
        let config: [String: Any] = ["model": "opus", "hooks": ["PreToolUse": [userHook]]]

        let once = HookInstaller.merged(config: config, agent: .claude, hookPath: hook)
        let twice = HookInstaller.merged(config: once, agent: .claude, hookPath: hook)
        XCTAssertEqual(once["model"] as? String, "opus")
        let pre = (twice["hooks"] as? [String: Any])?["PreToolUse"] as? [Any]
        XCTAssertEqual(pre?.count, 2)
        XCTAssertTrue(HookInstaller.isInstalled(config: twice, agent: .claude))

        let removed = HookInstaller.removed(config: twice, agent: .claude)
        XCTAssertFalse(HookInstaller.isInstalled(config: removed, agent: .claude))
        let kept = (removed["hooks"] as? [String: Any])?["PreToolUse"] as? [Any]
        XCTAssertEqual(kept?.count, 1)
        XCTAssertNil((removed["hooks"] as? [String: Any])?["Stop"])
    }

    func testClaudeRemoveDropsEmptyHooksKey() {
        let merged = HookInstaller.merged(config: [:], agent: .claude, hookPath: hook)
        XCTAssertNil(HookInstaller.removed(config: merged, agent: .claude)["hooks"])
    }

    func testCodexUsesTopLevelTableAndApprovalTimeout() {
        let merged = HookInstaller.merged(config: [:], agent: .codex, hookPath: hook)
        XCTAssertEqual(Set(merged.keys), Set(HookInstaller.events(for: .codex).map(\.rawValue)))
        let entry = (merged["PermissionRequest"] as? [Any])?.first as? [String: Any]
        let command = (entry?["hooks"] as? [Any])?.first as? [String: Any]
        XCTAssertEqual(command?["timeout"] as? Int, HookInstaller.approvalTimeoutSeconds)
        XCTAssertEqual(command?["command"] as? String, "'\(hook)' codex")
    }

    func testCommandQuotesPathsWithSpacesAndQuotes() {
        XCTAssertEqual(HookInstaller.command(hookPath: "/a b/it's/denny-hook", agent: .claude),
                       #"'/a b/it'\''s/denny-hook' claude"#)
    }

    func testFileInstallBacksUpAndRefusesUnreadableConfig() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dfa-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = HookInstaller.configURL(for: .claude, home: home)
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"theme":"dark"}"#.utf8).write(to: settings)

        try HookInstaller.install(agent: .claude, hookPath: hook, home: home)
        XCTAssertTrue(HookInstaller.isInstalled(agent: .claude, home: home))
        let backups = try FileManager.default.contentsOfDirectory(atPath: settings.deletingLastPathComponent().path)
            .filter { $0.contains("denny-backup") }
        XCTAssertEqual(backups.count, 1)

        try HookInstaller.uninstall(agent: .claude, home: home)
        let after = try HookInstaller.readConfig(at: settings)
        XCTAssertEqual(after["theme"] as? String, "dark")
        XCTAssertFalse(HookInstaller.isInstalled(agent: .claude, home: home))

        try Data("{ broken".utf8).write(to: settings)
        XCTAssertThrowsError(try HookInstaller.install(agent: .claude, hookPath: hook, home: home))
        XCTAssertEqual(try String(contentsOf: settings), "{ broken")
    }
}

final class RemoteBridgeTests: XCTestCase {
    /// Exactly what remote/denny-hook.py sends.
    func testDecodesPythonHookRequest() throws {
        let line = """
        {"version": 1, "id": "abc", "event": {"agent": "codex", "name": "PermissionRequest", "sessionId": "s1", \
        "host": "vps", "cwd": "/root/shop", "toolName": "Bash", "toolInput": {"command": ["bash", "-lc", "ls"], \
        "n": 3, "ok": true, "nested": {"x": null}}}, "wantsDecision": true, "token": "t"}
        """
        let request = try BridgeCodec.decode(BridgeRequest.self, line: Data(line.utf8))
        XCTAssertEqual(request.token, "t")
        XCTAssertEqual(request.event.host, "vps")
        XCTAssertEqual(request.event.agent, .codex)
        var store = AgentStore(language: .en)
        store.apply(request.event, requestId: request.id)
        XCTAssertEqual(store.approvals.first?.summary, "Runs ls")
        XCTAssertEqual(store.approvals.first?.host, "vps")
    }

    func testTokensMatch() {
        XCTAssertTrue(RemoteBridge.tokensMatch("abc", "abc"))
        XCTAssertFalse(RemoteBridge.tokensMatch("abd", "abc"))
        XCTAssertFalse(RemoteBridge.tokensMatch("ab", "abc"))
        XCTAssertFalse(RemoteBridge.tokensMatch(nil, "abc"))
    }

    func testTokenIsCreatedOnceAndPrivate() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dfa-token-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let first = try XCTUnwrap(RemoteBridge.loadOrCreateToken(home: home))
        XCTAssertEqual(first.count, 48)
        XCTAssertEqual(RemoteBridge.loadOrCreateToken(home: home), first)
        let attributes = try FileManager.default.attributesOfItem(atPath: BridgePaths.remoteToken(home: home).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testLoopbackRoundTrip() throws {
        var listener: UnixSocket?
        var port: UInt16 = 0
        for candidate in UInt16(47400)..<UInt16(47450) {
            if let socket = UnixSocket.listenLoopback(port: candidate) {
                listener = socket
                port = candidate
                break
            }
        }
        let server = try XCTUnwrap(listener)
        DispatchQueue.global().async {
            guard let client = server.accept(), let line = client.readLine() else { return }
            var reply = line
            reply.append(0x0A)
            client.write(reply)
        }
        let socket = try XCTUnwrap(UnixSocket.connectLoopback(port: port))
        XCTAssertTrue(socket.write(Data("ping\n".utf8)))
        socket.setReceiveTimeout(seconds: 5)
        XCTAssertEqual(socket.readLine(), Data("ping".utf8))
        server.close()
    }
}

final class UsageTests: XCTestCase {
    /// Verbatim shape of `denny-hook.py --report` output.
    private let pythonReport = """
    {"host": "srv1782466", "generatedAt": 1790827119.9691796, "usage": [{"hour": 1789012800.0, "agent": "claude", \
    "model": "claude-sonnet-5", "input": 48, "cacheWrite5m": 0, "cacheWrite1h": 161628, "cacheRead": 2851992, \
    "output": 44903}], "limits": [{"agent": "claude", "plan": "Pro", "windows": [{"kind": "session", "label": null, \
    "percent": 0.0, "resetsAt": null}, {"kind": "weekly", "label": null, "percent": 0.0, "resetsAt": 1790924400}], \
    "observedAt": 1790789507.937}, {"agent": "codex", "observedAt": 1790305530.0, "windows": [], "plan": null}], \
    "activity": [{"agent": "claude", "at": 1790827097.0}, {"agent": "codex", "at": 1790178223.0}]}
    """

    func testDecodesPythonReport() throws {
        let report = try JSONDecoder().decode(UsageReport.self, from: Data(pythonReport.utf8))
        XCTAssertEqual(report.usage.first?.cacheWrite1h, 161628)
        XCTAssertEqual(report.limits.first?.plan, "Pro")
        XCTAssertEqual(report.limits.first?.windows.last?.resetsAt, 1790924400)
        XCTAssertNil(report.limits.last?.plan)
    }

    func testPricing() {
        let item = UsageReport.Item(hour: 0, agent: .claude, model: "claude-opus-5-5", input: 1_000_000,
                                    cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        // 4 + 5 + 8 + 0.20 + 20
        XCTAssertEqual(Pricing.cost(item)!, 37.2, accuracy: 0.0001)
        XCTAssertEqual(Pricing.price(for: "claude-opus-5")?.input, 5)
        XCTAssertEqual(Pricing.price(for: "claude-sonnet-4-6[1m]")?.output, 15)
        XCTAssertNil(Pricing.price(for: "gpt-5.6-sol"))
        XCTAssertNil(Pricing.price(for: "claude-opus-4-1"))
    }

    func testCombinePeriodsLimitsAndActivity() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_790_827_200) // 04:00 UTC
        let today = calendar.startOfDay(for: now).timeIntervalSince1970
        let mac = UsageReport(host: "mac", generatedAt: 0, usage: [
            .init(hour: today, agent: .claude, model: "claude-opus-5-5", output: 1_000_000),
            .init(hour: today - 3 * 86400, agent: .claude, model: "claude-opus-5-5", output: 1_000_000)
        ], limits: [.init(agent: .claude, plan: "Pro", windows: [.init(kind: "session", percent: 10)], observedAt: 100)])
        let server = UsageReport(host: "vps", generatedAt: 0, usage: [
            .init(hour: today - 20 * 86400, agent: .codex, model: "gpt-5.6-sol", input: 100, cacheRead: 300)
        ], limits: [.init(agent: .claude, plan: "Pro", windows: [.init(kind: "session", percent: 96)], observedAt: 200)],
           activity: [.init(agent: .codex, at: 50)])

        let summary = UsageSummary.combine([mac, server], now: now, calendar: calendar)
        XCTAssertEqual(summary.spend[.today]?.cost ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(summary.spend[.week]?.cost ?? 0, 40, accuracy: 0.001)
        XCTAssertEqual(summary.spend[.week]?.fullyPriced, true)
        XCTAssertEqual(summary.spend[.month]?.fullyPriced, false)
        XCTAssertEqual(summary.spend[.month]?.cacheShare ?? 0, 0.75, accuracy: 0.001)
        XCTAssertEqual(summary.limits[.claude]?.windows.first?.percent, 96)
        XCTAssertEqual(summary.lastActivity[.codex], Date(timeIntervalSince1970: 50))
        XCTAssertEqual(summary.agentsSeen, [.claude, .codex])
    }

    func testBridgeRequestCarriesReport() throws {
        let line = #"{"version": 1, "id": "x", "event": {"agent": "claude", "name": "Other", "sessionId": "usage-report"}, "wantsDecision": false, "token": "t", "report": "# + pythonReport + "}"
        let request = try BridgeCodec.decode(BridgeRequest.self, line: Data(line.utf8))
        XCTAssertEqual(request.report?.host, "srv1782466")
        XCTAssertEqual(request.event.name, .other)
    }
}

final class ShellQuoteTests: XCTestCase {
    func testQuotesOnlyWhenNeeded() {
        XCTAssertEqual(ShellQuote.quote("/Users/t/a.swift"), "/Users/t/a.swift")
        XCTAssertEqual(ShellQuote.quote("/Users/t/My File.pdf"), "'/Users/t/My File.pdf'")
        XCTAssertEqual(ShellQuote.quote("/tmp/it's"), #"'/tmp/it'\''s'"#)
        XCTAssertEqual(ShellQuote.quote("/tmp/Отчёт.txt"), "'/tmp/Отчёт.txt'")
        XCTAssertEqual(ShellQuote.join(["/a", "/b c"]), "/a '/b c'")
    }
}

final class FileOutboxTests: XCTestCase {
    func testSafeNameAndPath() {
        XCTAssertEqual(FileOutbox.safeName("../../etc/passwd"), "passwd")
        XCTAssertEqual(FileOutbox.safeName(".."), "file")
        XCTAssertEqual(FileOutbox.safeName("Отчёт 1.pdf"), "Отчёт 1.pdf")
        XCTAssertEqual(FileOutbox.remotePath(home: "/root", dir: "20261001-153000", name: "a b.pdf"),
                       "/root/denny-inbox/20261001-153000/a b.pdf")
    }

    func testTakeIsPerHostOnceAndExpires() {
        var outbox = FileOutbox()
        let now = Date()
        outbox.add([.init(dir: "d", name: "a", data: Data("x".utf8), createdAt: now),
                    .init(dir: "d", name: "old", data: Data(), createdAt: now.addingTimeInterval(-FileOutbox.lifetime - 1))],
                   host: "vps")
        XCTAssertTrue(outbox.take(host: "other", now: now).isEmpty)
        XCTAssertEqual(outbox.take(host: "vps", now: now).map(\.name), ["a"])
        XCTAssertTrue(outbox.take(host: "vps", now: now).isEmpty)
    }

    func testDeliveryEncodesBase64() throws {
        let delivery = FileDelivery(id: "r", items: [.init(dir: "d", name: "../x", data: Data("hi".utf8), createdAt: Date())])
        XCTAssertEqual(delivery.files.first?.name, "x")
        XCTAssertEqual(delivery.files.first?.data, "aGk=")
        let event = try BridgeCodec.decode(BridgeRequest.self, line: Data(#"{"version":1,"id":"r","event":{"agent":"claude","name":"UserPromptSubmit","sessionId":"s","home":"/root"},"wantsDecision":false,"wantsFiles":true}"#.utf8))
        XCTAssertEqual(event.wantsFiles, true)
        XCTAssertEqual(event.event.home, "/root")
    }
}

final class TurnTimerTests: XCTestCase {
    func testTurnStartsOnPromptAndEndsOnStop() {
        var store = AgentStore(language: .en)
        let t0 = Date(timeIntervalSince1970: 1_000)
        store.apply(HookEvent(agent: .claude, name: .userPromptSubmit, sessionId: "s"), now: t0)
        store.apply(HookEvent(agent: .claude, name: .preToolUse, sessionId: "s", toolName: "Read"), now: t0.addingTimeInterval(30))
        XCTAssertEqual(store.sessions["claude:s"]?.turnStartedAt, t0)
        store.apply(HookEvent(agent: .claude, name: .stop, sessionId: "s"), now: t0.addingTimeInterval(60))
        XCTAssertNil(store.sessions["claude:s"]?.turnStartedAt)
        // A session first seen mid-turn starts its timer at the first tool call.
        store.apply(HookEvent(agent: .codex, name: .preToolUse, sessionId: "x", toolName: "Bash"), now: t0)
        XCTAssertEqual(store.sessions["codex:x"]?.turnStartedAt, t0)
    }
}

final class ResetsTests: XCTestCase {
    func testNewestResetsWinAndOldReportsDecode() throws {
        let old = try JSONDecoder().decode(UsageReport.self, from: Data(#"{"host":"a","generatedAt":1,"usage":[],"limits":[],"activity":[]}"#.utf8))
        XCTAssertNil(old.resets)
        let mac = UsageReport(host: "mac", generatedAt: 0, resets: [.init(agent: .codex, available: 2, observedAt: 10)])
        let vps = UsageReport(host: "vps", generatedAt: 0, resets: [.init(agent: .codex, available: 1, nextExpiresAt: 99, observedAt: 20)])
        let summary = UsageSummary.combine([mac, vps, old])
        XCTAssertEqual(summary.resets[.codex]?.available, 1)
        XCTAssertEqual(summary.resets[.codex]?.nextExpiresAt, 99)
    }
}


final class AlertTests: XCTestCase {
    func testFinishRule() {
        let settings = AlertSettings(finishAfterMinutes: 2)
        XCTAssertFalse(settings.notifiesFinish(after: 60))
        XCTAssertTrue(settings.notifiesFinish(after: 125))
        XCTAssertFalse(settings.notifiesFinish(after: nil))
        XCTAssertTrue(AlertSettings(finishAfterMinutes: 0).notifiesFinish(after: nil))
        XCTAssertFalse(AlertSettings(finishAfterMinutes: nil).notifiesFinish(after: 9999))
    }

    func testLimitAlertsOncePerPeriod() {
        var summary = UsageSummary()
        summary.limits[.codex] = .init(agent: .codex, windows: [
            .init(kind: "weekly", percent: 85, resetsAt: 1_791_332_228),
            .init(kind: "session", percent: 40, resetsAt: 1_790_900_000)
        ], observedAt: 0)
        var tracker = AlertTracker()
        let settings = AlertSettings(limitPercent: 80)
        XCTAssertEqual(tracker.limitAlerts(summary, settings: settings).map { $0.window.kind }, ["weekly"])
        XCTAssertTrue(tracker.limitAlerts(summary, settings: settings).isEmpty)
        summary.limits[.codex]?.windows[0].resetsAt = 1_791_937_028
        XCTAssertEqual(tracker.limitAlerts(summary, settings: settings).count, 1)
        XCTAssertTrue(tracker.limitAlerts(summary, settings: AlertSettings(limitPercent: nil)).isEmpty)
    }

    func testBudgetOncePerDay() {
        var tracker = AlertTracker()
        let settings = AlertSettings(dailyBudget: 25)
        XCTAssertFalse(tracker.budgetAlert(spentToday: 10, settings: settings, day: "2026-10-01"))
        XCTAssertTrue(tracker.budgetAlert(spentToday: 26, settings: settings, day: "2026-10-01"))
        XCTAssertFalse(tracker.budgetAlert(spentToday: 40, settings: settings, day: "2026-10-01"))
        XCTAssertTrue(tracker.budgetAlert(spentToday: 26, settings: settings, day: "2026-10-02"))
    }
}

final class ActivityMapTests: XCTestCase {
    func testThirteenWeeksStreakAndBusiestDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        let now = Date(timeIntervalSince1970: 1_790_841_600 + 3600) // Thursday 2026-10-01 09:00 UTC
        let today = calendar.startOfDay(for: now).timeIntervalSince1970
        func item(daysAgo: Double, tokens: Int) -> UsageReport.Item {
            .init(hour: today - daysAgo * 86400 + 7200, agent: .claude, model: "claude-opus-5-5", output: tokens)
        }
        let report = UsageReport(host: "m", generatedAt: 0, usage: [
            item(daysAgo: 1, tokens: 10), item(daysAgo: 2, tokens: 50), item(daysAgo: 3, tokens: 5),
            item(daysAgo: 6, tokens: 7), item(daysAgo: 200, tokens: 999)
        ])
        let summary = UsageSummary.combine([report], now: now, calendar: calendar)
        XCTAssertEqual(summary.days.first.map { calendar.component(.weekday, from: $0.start) }, 2)
        XCTAssertEqual(summary.days.last?.start, Date(timeIntervalSince1970: today))
        XCTAssertEqual(summary.days.count, 12 * 7 + 4)
        XCTAssertEqual(summary.streak, 3)
        XCTAssertEqual(summary.activeDays, 4)
        XCTAssertEqual(summary.busiestDay?.tokens, 50)
    }
}

final class LocalizationTests: XCTestCase {
    private func placeholders(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:ld|@|d)|%%"#)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { String(text[Range($0.range, in: text)!]) }.sorted()
    }

    func testEveryLanguageHasEveryKeyWithSamePlaceholders() {
        for language in UILanguage.allCases {
            let table = Translations.tables[language] ?? [:]
            XCTAssertEqual(Set(table.keys), Set(Translations.english.keys), "\(language)")
            for (key, english) in Translations.english {
                XCTAssertEqual(placeholders(table[key] ?? ""), placeholders(english), "\(language) \(key)")
            }
        }
    }

    func testFormattingAndFallback() {
        XCTAssertEqual(Translations.format("alerts.limitTitle", .ru, ["Codex", 100]), "Лимит Codex: 100%")
        XCTAssertEqual(Translations.format("time.daysHours", .ja, [5, 20]), "5日 20時間")
        XCTAssertEqual(Translations.text("no.such.key", .de), "no.such.key")
        XCTAssertEqual(Translations.format("resets.line", .fr, [12345]), "Réinitialisations : 12345")
        XCTAssertTrue(Translations.text("remote.body", .en).contains("ssh -R {port}:127.0.0.1:{port}"))
    }

    func testLanguageDetection() {
        XCTAssertEqual(UILanguage.from(preferred: ["ru-RU"]), .ru)
        XCTAssertEqual(UILanguage.from(preferred: ["zh-Hant-TW"]), .zhHans)
        XCTAssertEqual(UILanguage.from(preferred: ["pt-PT"]), .ptBR)
        XCTAssertEqual(UILanguage.from(preferred: ["it-IT", "de-DE"]), .de)
        XCTAssertEqual(UILanguage.from(preferred: ["it-IT"]), .en)
        XCTAssertEqual(StepDescriber.describe(toolName: "Read", toolInput: ["file_path": .string("/a/x.swift")], language: .ko), "x.swift 읽는 중")
    }
}

final class StepKindTests: XCTestCase {
    func testWritingAndPlanningStartOnceUntilTheKindChanges() {
        var store = AgentStore(language: .en)
        let t0 = Date(timeIntervalSince1970: 1_000)
        func tool(_ name: String) -> [AgentStoreEffect] {
            store.apply(HookEvent(agent: .claude, name: .preToolUse, sessionId: "s", toolName: name), now: t0)
        }
        XCTAssertEqual(store.apply(HookEvent(agent: .claude, name: .userPromptSubmit, sessionId: "s"), now: t0),
                       [.turnStarted(sessionKey: "claude:s")])
        XCTAssertEqual(tool("Read"), [])
        XCTAssertEqual(tool("Edit"), [.startedStep(sessionKey: "claude:s", kind: .writing)])
        XCTAssertEqual(tool("Write"), [])
        XCTAssertEqual(tool("TodoWrite"), [.startedStep(sessionKey: "claude:s", kind: .planning)])
        XCTAssertEqual(tool("apply_patch"), [.startedStep(sessionKey: "claude:s", kind: .writing)])
        XCTAssertEqual(store.sessions["claude:s"]?.stepKind, .writing)
        store.apply(HookEvent(agent: .claude, name: .stop, sessionId: "s"), now: t0)
        XCTAssertNil(store.sessions["claude:s"]?.stepKind)
    }
}

final class BreakdownTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testSharesTrendAndPlanPrice() {
        let now = Date(timeIntervalSince1970: 1_790_812_800 + 10 * 3600) // 10:00 UTC
        let today = 1_790_812_800.0
        let report = UsageReport(host: "m", generatedAt: 0, usage: [
            .init(hour: today + 3600, agent: .claude, model: "claude-opus-5-5", project: "shop", output: 1_000_000),
            .init(hour: today + 7200, agent: .claude, model: "claude-sonnet-5-5", project: "shop", output: 1_000_000),
            .init(hour: today - 86400, agent: .codex, model: "gpt-5.6-sol", project: "app", input: 500),
            .init(hour: today + 3600, agent: .claude, model: "claude-opus-5-5", project: "", output: 1_000_000)
        ], limits: [.init(agent: .claude, plan: "Pro", planPrice: 20, windows: [], observedAt: 1)])
        let summary = UsageSummary.combine([report], now: now, calendar: calendar)

        XCTAssertEqual(summary.models[.today]?.map(\.name), ["claude-opus-5-5", "claude-sonnet-5-5"])
        XCTAssertEqual(summary.models[.today]?.first?.cost ?? 0, 40, accuracy: 0.001)
        XCTAssertEqual(Set(summary.projects[.today]?.map(\.name) ?? []), ["shop", "Claude Code"])
        XCTAssertEqual(summary.projects[.week]?.first { $0.name == "app" }?.fullyPriced, false)
        XCTAssertEqual(summary.trend[.today]?.count, 11)
        XCTAssertEqual(summary.trend[.today]?[1].cost[.claude] ?? 0, 40, accuracy: 0.001)
        XCTAssertEqual(summary.trend[.week]?.count, 7)
        XCTAssertEqual(summary.trend[.month]?.count, 30)
        XCTAssertEqual(summary.trend[.week]?[5].tokens[.codex], 500)
        XCTAssertEqual(summary.limits[.claude]?.planPrice, 20)
    }

    func testPriceOverridesFromJSON() throws {
        let json = #"{"models": {"gpt-5.6": {"input": 1.25, "output": 10}, "claude-opus-5-5": {"input": 3, "output": 15, "cacheRead": 0.1}}}"#
        let overrides = try XCTUnwrap(Pricing.overrides(fromJSON: Data(json.utf8)))
        Pricing.overrides = overrides
        defer { Pricing.overrides = [] }
        XCTAssertEqual(Pricing.price(for: "gpt-5.6-sol")?.cacheRead ?? 0, 0.125, accuracy: 0.0001)
        XCTAssertEqual(Pricing.price(for: "claude-opus-5-5")?.input, 3)
        XCTAssertEqual(Pricing.price(for: "claude-haiku-4-5")?.input, 1)
    }

    func testLimitRenewal() {
        var summary = UsageSummary()
        summary.limits[.codex] = .init(agent: .codex, windows: [.init(kind: "weekly", percent: 100)], observedAt: 0)
        let first = LimitRenewal.detect(previous: [:], summary: summary)
        XCTAssertTrue(first.renewed.isEmpty)
        summary.limits[.codex]?.windows[0].percent = 3
        let second = LimitRenewal.detect(previous: first.levels, summary: summary)
        XCTAssertEqual(second.renewed.map { $0.window.percent }, [3])
        XCTAssertTrue(LimitRenewal.detect(previous: second.levels, summary: summary).renewed.isEmpty)
    }
}

final class LimitFreshnessTests: XCTestCase {
    func testPassedResetMeansRenewedAndOldReadingIsUnknown() {
        let now = 1_000_000.0
        let passed = UsageReport.Window(kind: "weekly", percent: 100, resetsAt: now - 60).current(observedAt: now - 3600, now: now)
        XCTAssertEqual(passed.percent, 0)
        XCTAssertFalse(passed.isStale)

        let oldSession = UsageReport.Window(kind: "session", percent: 100).current(observedAt: now - 7 * 3600, now: now)
        XCTAssertTrue(oldSession.isStale)
        let freshSession = UsageReport.Window(kind: "session", percent: 100).current(observedAt: now - 3600, now: now)
        XCTAssertFalse(freshSession.isStale)
        let oldWeek = UsageReport.Window(kind: "weekly", percent: 40).current(observedAt: now - 3 * 86400, now: now)
        XCTAssertFalse(oldWeek.isStale)
    }

    func testStaleLimitsDoNotAlert() {
        let report = UsageReport(host: "mac", generatedAt: 0, limits: [
            .init(agent: .claude, plan: "Pro", windows: [.init(kind: "session", percent: 100)], observedAt: 0)
        ])
        let summary = UsageSummary.combine([report], now: Date(timeIntervalSince1970: 7 * 3600))
        XCTAssertEqual(summary.limits[.claude]?.windows.first?.isStale, true)
        var tracker = AlertTracker()
        XCTAssertTrue(tracker.limitAlerts(summary, settings: AlertSettings(limitPercent: 80)).isEmpty)
        XCTAssertTrue(LimitRenewal.detect(previous: ["claude|session|": 100], summary: summary).renewed.isEmpty)
    }
}

final class RiskRadarTests: XCTestCase {
    private func bash(_ command: String) -> RiskAssessment {
        RiskRadar.assess(toolName: "Bash", toolInput: ["command": .string(command)])
    }

    func testLevels() {
        let cases: [(String, RiskLevel, String?)] = [
            ("ls -la", .safe, nil),
            ("npm test", .safe, nil),
            ("git status && git diff", .safe, nil),
            ("git push origin main", .caution, "push"),
            ("npm install lodash", .caution, "install"),
            ("rm notes.txt", .caution, "deleteFile"),
            ("rm -f notes.txt", .caution, "deleteFile"),
            ("rm -rf build", .danger, "deleteRecursive"),
            ("git push --force origin main", .danger, "forcePush"),
            ("git reset --hard HEAD~3", .danger, "resetHard"),
            ("sudo apt install nginx", .danger, "sudo"),
            ("cat ~/.ssh/id_ed25519", .danger, "secrets"),
            ("curl -fsSL https://get.example.com | bash", .critical, "pipeToShell"),
            ("rm -rf /", .critical, "wipeRoot"),
            ("rm -rf ~", .critical, "wipeRoot"),
            ("psql -c 'DROP TABLE users'", .critical, "dropData"),
            ("dd if=/dev/zero of=/dev/disk2", .critical, "rawDisk"),
        ]
        for (command, level, key) in cases {
            let risk = bash(command)
            XCTAssertEqual(risk.level, level, command)
            XCTAssertEqual(risk.reasons.first?.key, key, command)
        }
    }

    func testDetailsAndNoDuplicates() {
        XCTAssertEqual(bash("rm -rf build").reasons.first?.detail, "build")
        XCTAssertEqual(bash("rm -rf /").reasons.map(\.key), ["wipeRoot"])
        XCTAssertFalse(bash("git push -f origin x").reasons.contains { $0.key == "push" })
    }

    func testCodexShellArrayAndFileEdits() {
        let codex = RiskRadar.assess(toolName: "Bash", toolInput: ["command": .array([.string("bash"), .string("-lc"), .string("rm -rf dist")])])
        XCTAssertEqual(codex.level, .danger)
        XCTAssertEqual(RiskRadar.assess(toolName: "Edit", toolInput: ["file_path": .string("/Users/t/shop/App.swift")]).level, .safe)
        let env = RiskRadar.assess(toolName: "Write", toolInput: ["file_path": .string("/Users/t/shop/.env")])
        XCTAssertEqual(env.level, .danger)
        XCTAssertEqual(env.reasons.first?.detail, ".env")
        XCTAssertEqual(RiskRadar.assess(toolName: "Edit", toolInput: ["file_path": .string("~/.zshrc")]).level, .danger)
        XCTAssertEqual(RiskRadar.assess(toolName: "mcp__github__create_issue", toolInput: [:]).level, .caution)
    }

    func testApprovalCarriesRisk() {
        var store = AgentStore(language: .en)
        store.apply(HookEvent(agent: .claude, name: .permissionRequest, sessionId: "s", toolName: "Bash",
                              toolInput: ["command": .string("rm -rf node_modules")]), requestId: "r")
        XCTAssertEqual(store.approvals.first?.risk.level, .danger)
        XCTAssertEqual(Translations.format("risk.reason.deleteRecursive", .ru, ["node_modules"]),
                       "Удалит папку node_modules со всем содержимым, без Корзины.")
    }
}

final class RelayTests: XCTestCase {
    private func workedSession(_ store: inout AgentStore, now: Date) {
        store.apply(HookEvent(agent: .claude, name: .userPromptSubmit, sessionId: "s", cwd: "/root/shop",
                              prompt: "Add a cart page", host: "vps"), now: now)
        store.apply(HookEvent(agent: .claude, name: .preToolUse, sessionId: "s", toolName: "Edit",
                              toolInput: ["file_path": .string("/root/shop/src/Cart.swift")]), now: now)
        store.apply(HookEvent(agent: .claude, name: .preToolUse, sessionId: "s", toolName: "Bash",
                              toolInput: ["command": .string("swift test")]), now: now)
        store.apply(HookEvent(agent: .claude, name: .stop, sessionId: "s", lastAssistantMessage: "Tests pass, styling left."), now: now)
    }

    func testSessionRemembersWork() {
        var store = AgentStore(language: .en)
        workedSession(&store, now: Date())
        let session = store.sessions["claude:s"]!
        XCTAssertEqual(session.lastPrompt, "Add a cart page")
        XCTAssertEqual(session.touchedFiles, ["/root/shop/src/Cart.swift"])
        XCTAssertEqual(session.commands, ["swift test"])
    }

    func testOfferWhenOneAgentIsOutAndTheOtherHasRoom() {
        var store = AgentStore(language: .en)
        let now = Date()
        workedSession(&store, now: now)
        var summary = UsageSummary()
        summary.limits[.claude] = .init(agent: .claude, windows: [.init(kind: "session", percent: 100, resetsAt: now.timeIntervalSince1970 + 3600)], observedAt: now.timeIntervalSince1970)
        summary.limits[.codex] = .init(agent: .codex, windows: [.init(kind: "weekly", percent: 40)], observedAt: now.timeIntervalSince1970)
        let offer = Relay.offer(summary: summary, sessions: Array(store.sessions.values), available: [.claude, .codex], now: now)
        XCTAssertEqual(offer?.from, .claude)
        XCTAssertEqual(offer?.to, .codex)
        XCTAssertNil(Relay.offer(summary: summary, sessions: Array(store.sessions.values), available: [.claude], now: now))
        summary.limits[.codex]?.windows[0].percent = 100
        XCTAssertNil(Relay.offer(summary: summary, sessions: Array(store.sessions.values), available: [.claude, .codex], now: now))
    }

    func testNoteSaysWhatWasAskedAndDone() {
        var store = AgentStore(language: .en)
        workedSession(&store, now: Date())
        let note = Relay.note(for: store.sessions["claude:s"]!, to: .codex, becauseOfLimit: true, language: .en)
        XCTAssertTrue(note.hasPrefix("Continue a task that Claude Code started (it hit its plan limit)."))
        XCTAssertTrue(note.contains("Folder: /root/shop"))
        XCTAssertTrue(note.contains("Server: vps"))
        XCTAssertTrue(note.contains("Add a cart page"))
        XCTAssertTrue(note.contains("edited: src/Cart.swift"))
        XCTAssertTrue(note.contains("ran: swift test"))
        XCTAssertTrue(note.contains("Tests pass, styling left."))
        XCTAssertTrue(note.hasSuffix("then carry on from where it stopped."))
    }
}

final class StuckDetectorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 100_000)

    private func tool(_ store: inout AgentStore, _ name: String, _ input: [String: JSONValue], at minutes: Double) -> [AgentStoreEffect] {
        store.apply(HookEvent(agent: .claude, name: .preToolUse, sessionId: "s", toolName: name, toolInput: input),
                    now: t0.addingTimeInterval(minutes * 60))
    }

    func testRepeatedCommandWarnsOncePerTurn() {
        var store = AgentStore(language: .en)
        store.apply(HookEvent(agent: .claude, name: .userPromptSubmit, sessionId: "s"), now: t0)
        XCTAssertEqual(tool(&store, "Bash", ["command": .string("npm test")], at: 1), [])
        _ = tool(&store, "Edit", ["file_path": .string("/a/x.ts")], at: 2)
        XCTAssertEqual(tool(&store, "Bash", ["command": .string("npm test")], at: 3), [])
        XCTAssertEqual(tool(&store, "Bash", ["command": .string("npm test")], at: 5),
                       [.looksStuck(sessionKey: "claude:s", reason: .repeatedCommand(command: "npm test", times: 3))])
        XCTAssertEqual(tool(&store, "Bash", ["command": .string("npm test")], at: 6), [])
        store.apply(HookEvent(agent: .claude, name: .userPromptSubmit, sessionId: "s"), now: t0.addingTimeInterval(600))
        XCTAssertTrue(store.sessions["claude:s"]?.history.isEmpty == true)
    }

    func testRepeatedEditsAndSpreadOutRepeatsAreFine() {
        var store = AgentStore(language: .en)
        store.apply(HookEvent(agent: .claude, name: .userPromptSubmit, sessionId: "s"), now: t0)
        for minute in 0..<5 { _ = tool(&store, "Edit", ["file_path": .string("/a/Cart.swift")], at: Double(minute)) }
        XCTAssertEqual(tool(&store, "Edit", ["file_path": .string("/a/Cart.swift")], at: 6),
                       [.looksStuck(sessionKey: "claude:s", reason: .repeatedEdit(file: "Cart.swift", times: 6))])
        var spaced = AgentStore(language: .en)
        spaced.apply(HookEvent(agent: .claude, name: .userPromptSubmit, sessionId: "s"), now: t0)
        for minute in [0.0, 20, 40] {
            XCTAssertEqual(tool(&spaced, "Bash", ["command": .string("make")], at: minute), [])
        }
    }

    func testLongBusyStretchWithoutEdits() {
        var history: [StepRecord] = []
        for step in 0..<31 {
            history.append(StepRecord(at: t0.addingTimeInterval(120 + Double(step) * 20), kind: .reading, target: nil))
        }
        let now = t0.addingTimeInterval(21 * 60)
        XCTAssertEqual(StuckDetector.check(history, turnStartedAt: t0, now: now), .noProgress(minutes: 21))
        history.append(StepRecord(at: now, kind: .writing, target: "a.swift"))
        XCTAssertNil(StuckDetector.check(history, turnStartedAt: t0, now: now))
    }
}
