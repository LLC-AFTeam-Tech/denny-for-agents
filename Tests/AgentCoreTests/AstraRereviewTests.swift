import XCTest
@testable import AgentCore
import Foundation

final class AstraRereviewTests: XCTestCase {
    private func project(in location: URL = FileManager.default.temporaryDirectory) throws -> (URL, URL) {
        let home = location.appendingPathComponent("astra-dfa-\(UUID().uuidString)").resolvingSymlinksInPath()
        let repo = home.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "base\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "test@example.invalid"], ["config", "user.name", "Test"], ["add", "-A"], ["commit", "-qm", "base"]] {
            XCTAssertEqual(OfficeWorkspace.git(["-C", repo.path] + args).status, 0)
        }
        return (home, repo)
    }

    func testCommitFailureMustKeepUncommittedAgentWork() throws {
        let (home, repo) = try project()
        defer { try? FileManager.default.removeItem(at: home) }
        let prepared = OfficeWorkspace.prepare(OfficeTask(prompt: "Change a", agent: .claude, folder: repo.path), home: home)
        XCTAssertNil(prepared.error)
        let task = prepared.task
        let workdir = try XCTUnwrap(task.workdir)
        try "agent changes\n".write(toFile: workdir + "/a.txt", atomically: true, encoding: .utf8)
        // Real Git failure, independent of the user's global identity.
        XCTAssertEqual(OfficeWorkspace.git(["-C", repo.path, "config", "user.name", ""]).status, 0)
        XCTAssertNotNil(OfficeWorkspace.commitLeftovers(task))
        let error = OfficeWorkspace.accept(task)
        XCTAssertNotNil(error, "An uncommittable change must not be reported as accepted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workdir + "/a.txt"), "The agent's only copy was deleted")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8), "base\n")
    }

    func testAcceptMustNotAbortUsersExistingMerge() throws {
        let (home, repo) = try project()
        defer { try? FileManager.default.removeItem(at: home) }
        let run: ([String]) -> OfficeWorkspace.Output = { OfficeWorkspace.git(["-C", repo.path] + $0) }
        XCTAssertEqual(run(["checkout", "-qb", "feature"]).status, 0)
        try "feature\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(run(["commit", "-qam", "feature"]).status, 0)
        XCTAssertEqual(run(["checkout", "-q", "main"]).status, 0)
        try "main\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(run(["commit", "-qam", "main"]).status, 0)
        let prepared = OfficeWorkspace.prepare(OfficeTask(prompt: "Add b", agent: .codex, folder: repo.path), home: home)
        let task = prepared.task
        try "agent\n".write(toFile: try XCTUnwrap(task.workdir) + "/b.txt", atomically: true, encoding: .utf8)
        XCTAssertNil(OfficeWorkspace.commitLeftovers(task))
        XCTAssertNotEqual(run(["merge", "feature"]).status, 0)
        try "user's manual conflict resolution\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(run(["add", "a.txt"]).status, 0)
        XCTAssertEqual(run(["rev-parse", "--verify", "MERGE_HEAD"]).status, 0)
        XCTAssertNotNil(OfficeWorkspace.accept(task))
        XCTAssertEqual(run(["rev-parse", "--verify", "MERGE_HEAD"]).status, 0, "An unrelated user merge was aborted")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8), "user's manual conflict resolution\n")
    }

    func testLongCommandMustBeAssessedBeforeDisplayClipping() throws {
        let command = "printf '%s' '" + String(repeating: "x", count: HookEvent.maxTextLength + 100) + "'; rm -rf build"
        let payload = try JSONSerialization.data(withJSONObject: ["session_id": "test", "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": command]])
        let rawRisk = RiskRadar.assess(toolName: "Bash", toolInput: ["command": .string(command)])
        XCTAssertEqual(NightShift.decision(for: rawRisk), .deny)
        let event = try HookEvent.parse(payload, agent: .claude)
        let actual = RiskRadar.assess(toolName: event.toolName, toolInput: HookEvent.fullToolInput(payload))
        let displayRisk = RiskRadar.assess(toolName: event.toolName, toolInput: event.toolInput, clipped: event.inputClipped == true)
        XCTAssertEqual(NightShift.decision(for: displayRisk), .deny)
        XCTAssertEqual(NightShift.decision(for: actual), .deny, "The real local hook must use fullToolInput")
    }

    func testPatchMustAssessEveryChangedPath() {
        let patch = "*** Begin Patch\n*** Update File: src/public.txt\n@@\n-a\n+b\n*** Update File: .env\n@@\n-A=1\n+A=2\n*** End Patch"
        let actual = RiskRadar.assess(toolName: "apply_patch", toolInput: ["input": .string(patch)])
        XCTAssertGreaterThanOrEqual(actual.level, .danger, "A harmless first path hides the sensitive second file")
    }

    func testRemoteReworkWithoutSessionMustRetainOriginalTask() {
        let task = OfficeTask(prompt: "Original specification including required validation", agent: .claude, folder: "/srv/project", host: "test-server")
        let local = Office.reworkArguments(task, remarks: "Fix the remaining issue")
        XCTAssertTrue(local.contains { $0.contains(task.prompt) })
        let remote = Office.remoteRework(task, remarks: "Fix the remaining issue", settings: OfficeSettings())
        XCTAssertNil(remote.resume)
        XCTAssertTrue(remote.prompt?.contains(task.prompt) == true, "Without a session the remote agent gets only remarks")
    }

    func testDirectoryDeletionSnapshotMustIncludeIgnoredChildren() throws {
        // Use a real /Users path as real projects do; macOS /var aliases can
        // accidentally bypass the prefix test and cause a whole-folder copy.
        let (home, repo) = try project(in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        defer { try? FileManager.default.removeItem(at: home) }
        let src = repo.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "src/*.local\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "code\n".write(to: src.appendingPathComponent("code.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(OfficeWorkspace.git(["-C", repo.path, "add", "-A"]).status, 0)
        XCTAssertEqual(OfficeWorkspace.git(["-C", repo.path, "commit", "-qm", "source"]).status, 0)
        let ignored = src.appendingPathComponent("settings.local")
        try "important local configuration\n".write(to: ignored, atomically: true, encoding: .utf8)
        let snapshot = try XCTUnwrap(SafetyNet.take(command: "rm -rf src", cwd: repo.path, agent: "claude", home: home))
        XCTAssertNotNil(snapshot.ref, "The fixture must use a successful Git snapshot")
        try FileManager.default.removeItem(at: src)
        XCTAssertTrue(SafetyNet.restore(snapshot, home: home))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ignored.path), "The snapshot skipped ignored files inside a non-ignored directory")
    }
    func testDirectoryDeletionSnapshotMustIncludeIgnoredUnicodeChildren() throws {
        // Use a real /Users path as real projects do; macOS /var aliases can
        // accidentally bypass the prefix test and cause a whole-folder copy.
        let (home, repo) = try project(in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        defer { try? FileManager.default.removeItem(at: home) }
        let src = repo.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "src/*.local\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "code\n".write(to: src.appendingPathComponent("code.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(OfficeWorkspace.git(["-C", repo.path, "add", "-A"]).status, 0)
        XCTAssertEqual(OfficeWorkspace.git(["-C", repo.path, "commit", "-qm", "source"]).status, 0)
        let ignored = src.appendingPathComponent("настройки.local")
        try "important local configuration\n".write(to: ignored, atomically: true, encoding: .utf8)
        let snapshot = try XCTUnwrap(SafetyNet.take(command: "rm -rf src", cwd: repo.path, agent: "claude", home: home))
        XCTAssertNotNil(snapshot.ref, "The fixture must use a successful Git snapshot")
        try FileManager.default.removeItem(at: src)
        XCTAssertTrue(SafetyNet.restore(snapshot, home: home))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ignored.path), "The snapshot skipped ignored files inside a non-ignored directory")
    }
}
