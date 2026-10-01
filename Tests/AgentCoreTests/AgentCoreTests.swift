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
        XCTAssertEqual(effects, [.celebrate(sessionKey: "claude:s1")])
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
