import Foundation

/// "Office": tasks for Claude Code and Codex as if they were staff. Each task
/// runs in its own git branch and working copy, so the project itself is
/// untouched until the work is accepted, and two tasks never trip over each
/// other. Runs unattended under the night shift's careful policy.
public struct OfficeTask: Codable, Equatable, Sendable, Identifiable {
    public enum State: Codable, Equatable, Sendable {
        case queued
        case working(since: Date)
        /// Finished: waiting for the user to accept or throw away.
        case review(at: Date)
        case failed(at: Date, reason: String)
        case accepted(at: Date)
        case discarded(at: Date)

        public var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    public enum Column: String, CaseIterable, Sendable {
        case inbox, working, review, done
    }

    public var id: String
    public var prompt: String
    public var agent: AgentKind
    /// Where the user pointed: a project folder (or a folder inside one).
    public var folder: String
    /// The server it runs on; nil for this Mac.
    public var host: String?
    public var createdAt: Date
    public var state: State
    /// Set once the working copy exists (nil for a folder outside git: the
    /// agent then works in the folder itself).
    public var branch: String?
    public var workdir: String?
    /// The branch (or commit) the task started from.
    public var base: String?
    /// The agent's session, to carry on with "Rework".
    public var sessionId: String?
    public var report: OfficeReport?
    /// Given from Telegram: the report goes back there even if the user is at the Mac.
    public var fromPhone: Bool?
    /// "Rework" remarks waiting their turn: a rework goes through the same
    /// queue as a new task (one per folder, a couple at a time).
    public var rework: String?

    public init(id: String = UUID().uuidString, prompt: String, agent: AgentKind, folder: String, host: String? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.prompt = prompt
        self.agent = agent
        self.folder = folder
        self.host = host
        self.createdAt = createdAt
        self.state = .queued
    }

    public var column: Column {
        switch state {
        case .queued: return .inbox
        case .working: return .working
        case .review, .failed: return .review
        case .accepted, .discarded: return .done
        }
    }

    /// The first line, short enough for a card.
    public var title: String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 80 ? String(trimmed.prefix(79)) + "…" : trimmed
    }

    /// Where the agent runs: the same place inside its own working copy.
    public var runFolder: String { workdir ?? folder }
}

/// What the boss sees before deciding: the agent's own words, the change, the
/// tests, the price. Tokens and cost add up over reworks.
public struct OfficeReport: Codable, Equatable, Sendable {
    public var summary: String?
    public var files: [String] = []
    public var added = 0
    public var removed = 0
    public var tokens = 0
    public var cost: Double?
    /// "passed" / "failed"; nil when no tests were found.
    public var tests: String?
    public var testOutput: String?
    /// The second agent's review (Office settings → review).
    public var review: String?
    public var reviewer: AgentKind?
    public var findings: Int?

    public init() {}

    /// `git diff --numstat` lines: added, removed, path ("-" for binary files).
    public mutating func setChanges(numstat: String) {
        files = []
        added = 0
        removed = 0
        for line in numstat.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            added += Int(parts[0]) ?? 0
            removed += Int(parts[1]) ?? 0
            files.append(parts[2])
        }
    }

    public mutating func addUsage(tokens: Int, cost: Double?) {
        self.tokens += tokens
        if let cost { self.cost = (self.cost ?? 0) + cost }
    }
}

public enum Office {
    /// Tasks running at once on this Mac (memory and plan limits are shared).
    public static let maxParallel = 2
    public static let keepFinished = 50

    public static func file(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        BridgePaths.directory(home: home).appendingPathComponent("office.json")
    }

    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [OfficeTask] {
        guard let data = try? Data(contentsOf: file(home: home)) else { return [] }
        return (try? JSONDecoder().decode([OfficeTask].self, from: data)) ?? []
    }

    public static func save(_ tasks: [OfficeTask], home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        try? FileManager.default.createDirectory(at: BridgePaths.directory(home: home), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // Everything still open, plus the newest finished ones.
        let open = tasks.filter { $0.column != .done }
        let finished = tasks.filter { $0.column == .done }.suffix(keepFinished)
        guard let data = try? JSONEncoder().encode(open + finished) else { return }
        try? data.write(to: file(home: home), options: .atomic)
    }

    /// Queued tasks (of `host`) that may start now, oldest first: one task per
    /// folder at a time, at most `maxParallel` in all.
    public static func startable(_ tasks: [OfficeTask], host: String? = nil) -> [OfficeTask] {
        let mine = tasks.filter { $0.host == host }
        var busy = Set(mine.filter { $0.column == .working }.map(\.folder))
        var free = maxParallel - mine.filter { $0.column == .working }.count
        var result: [OfficeTask] = []
        for task in mine.sorted(by: { $0.createdAt < $1.createdAt }) where task.state == .queued && free > 0 {
            guard !busy.contains(task.folder) else { continue }
            busy.insert(task.folder)
            free -= 1
            result.append(task)
        }
        return result
    }

    /// After a restart nothing is running any more.
    public static func interrupted(_ tasks: [OfficeTask], reason: String, now: Date = Date()) -> [OfficeTask] {
        tasks.map { task in
            var task = task
            // A server's task goes on there whatever happens to this app.
            if case .working = task.state, task.host == nil { task.state = .failed(at: now, reason: reason) }
            return task
        }
    }

    /// The headless command line, under the careful policy (the hook knows by
    /// the environment); edits land in the task's own working copy.
    public static func arguments(_ task: OfficeTask, settings: OfficeSettings = OfficeSettings()) -> [String] {
        NightShift.arguments(NightJob(agent: task.agent, folder: task.runFolder, prompt: task.prompt,
                                      trigger: .at(task.createdAt), resume: nil))
            + budgetArguments(agent: task.agent, settings: settings)
    }

    /// "Rework": the same agent goes on in the same working copy with the
    /// boss's remarks. Without a known session it starts over with both texts.
    public static func reworkArguments(_ task: OfficeTask, remarks: String, settings: OfficeSettings = OfficeSettings()) -> [String] {
        let text = remarks.trimmingCharacters(in: .whitespacesAndNewlines)
        let budget = budgetArguments(agent: task.agent, settings: settings)
        if let session = task.sessionId, PhoneReplies.isValidSession(session) {
            return NightShift.arguments(NightJob(agent: task.agent, folder: task.runFolder, prompt: reworkPrompt(text),
                                                 trigger: .at(task.createdAt), resume: session)) + budget
        }
        return NightShift.arguments(NightJob(agent: task.agent, folder: task.runFolder,
                                             prompt: task.prompt + "\n\n" + reworkPrompt(text), trigger: .at(task.createdAt))) + budget
    }

    /// Office jobs for a server's worker.
    public static func remoteStart(_ task: OfficeTask, settings: OfficeSettings) -> RemoteJob {
        var job = RemoteJob(id: task.id, kind: .office, cwd: task.folder, agent: task.agent, prompt: task.prompt)
        job.review = settings.review ? true : nil
        job.budgetUSD = task.agent == .claude ? settings.claudeBudget : nil
        job.budgetTokens = task.agent == .codex ? settings.codexBudgetK.map { $0 * 1000 } : nil
        return job
    }

    public static func remoteRework(_ task: OfficeTask, remarks: String, settings: OfficeSettings) -> RemoteJob {
        var job = remoteStart(task, settings: settings)
        job.id = UUID().uuidString
        job.kind = .officeRework
        job.target = task.id
        let text = remarks.trimmingCharacters(in: .whitespacesAndNewlines)
        job.resume = task.sessionId.flatMap { PhoneReplies.isValidSession($0) ? $0 : nil }
        // Without the session the agent starts over: it needs the task itself too.
        job.prompt = job.resume == nil ? task.prompt + "\n\n" + reworkPrompt(text) : reworkPrompt(text)
        return job
    }

    public static func remoteDecision(_ task: OfficeTask, accept: Bool) -> RemoteJob {
        RemoteJob(kind: accept ? .officeAccept : .officeDiscard, target: task.id)
    }

    /// A server's report on its task: the new state (nil for one we don't know).
    public static func apply(_ result: RemoteJobResult, to task: inout OfficeTask, now: Date = Date()) -> Bool {
        switch result.state {
        case "running": task.state = .working(since: now)
        case "review": task.state = .review(at: now)
        case "failed": task.state = .failed(at: now, reason: result.output ?? "—")
        case "accepted": task.state = .accepted(at: now)
        case "discarded": task.state = .discarded(at: now)
        case "acceptFailed": return true  // stays for review; the caller shows why
        default: return false
        }
        // The server knows the session even when the Mac missed its events.
        if let session = result.session, PhoneReplies.isValidSession(session) { task.sessionId = session }
        if result.state == "review" || result.state == "failed" {
            var report = task.report ?? OfficeReport()
            if let files = result.files { report.files = files }
            if let added = result.added { report.added = added }
            if let removed = result.removed { report.removed = removed }
            report.tests = result.tests
            report.testOutput = result.testOutput
            report.review = result.review
            report.reviewer = result.reviewer
            report.findings = result.review.map(CrossReview.findings(in:))
            task.report = report
        }
        return true
    }

    /// The tests to run in a task's working copy. A fresh copy has no
    /// installed JavaScript packages (they aren't in git): those would fail for
    /// a reason that isn't the agent's, so they're skipped.
    public static func testCommand(runFolder: String) -> (root: String, command: String)? {
        guard let found = TestRunner.detect(cwd: runFolder) else { return nil }
        let fm = FileManager.default
        let js = fm.fileExists(atPath: (found.root as NSString).appendingPathComponent("package.json"))
        if js && !fm.fileExists(atPath: (found.root as NSString).appendingPathComponent("node_modules")) { return nil }
        return found
    }

    /// Where a run's output goes (the newest run of each task).
    public static func logFile(for task: OfficeTask, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        BridgePaths.directory(home: home).appendingPathComponent("office-logs").appendingPathComponent(task.id + ".log")
    }

    /// "exit 1" says nothing: the last lines the agent printed say why.
    public static func failureReason(log: String?, status: Int32) -> String {
        let lines = (log ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tail = lines.suffix(3).joined(separator: " · ")
        return tail.isEmpty ? "exit \(status)" : "exit \(status): " + String(tail.suffix(300))
    }

    public static func reworkPrompt(_ remarks: String) -> String {
        "The user reviewed your work on this task and asks for changes. Make them in the project's files, "
            + "the same way you did the task itself (don't just answer in text), then say briefly what you changed:\n\n" + remarks
    }

    /// The newest folders tasks went to (and agents worked in) on this Mac, for
    /// "which project?" — never Office's own working copies.
    public static func recentFolders(_ candidates: [String], limit: Int = 4,
                                     home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let own = BridgePaths.directory(home: home).path
        var seen = Set<String>()
        var result: [String] = []
        for folder in candidates where !folder.isEmpty && !folder.hasPrefix(own) && !seen.contains(folder) {
            seen.insert(folder)
            result.append(folder)
            if result.count == limit { break }
        }
        return result
    }

    // MARK: - Git

    public static func branch(for task: OfficeTask) -> String {
        "denny/office-" + task.id.prefix(8).lowercased()
    }

    /// Outside the project, so the main checkout never sees it as an untracked folder.
    public static func workdir(for task: OfficeTask, repoRoot: String,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let name = (repoRoot as NSString).lastPathComponent
        return BridgePaths.directory(home: home).appendingPathComponent("office")
            .appendingPathComponent(name + "-" + task.id.prefix(8).lowercased()).path
    }

    /// The same subfolder inside the working copy as `folder` is inside the repo.
    public static func runFolder(folder: String, repoRoot: String, workdir: String) -> String {
        // /tmp and /var are /private/... on a Mac: compare real paths.
        let root = (repoRoot as NSString).resolvingSymlinksInPath
        let path = (folder as NSString).resolvingSymlinksInPath
        guard path.hasPrefix(root + "/") else { return workdir }
        return (workdir as NSString).appendingPathComponent(String(path.dropFirst(root.count + 1)))
    }

    /// `git` arguments; run with /usr/bin/git, no shell.
    public enum Git {
        public static func repoRoot(_ folder: String) -> [String] { ["-C", folder, "rev-parse", "--show-toplevel"] }
        /// "HEAD" when detached: then the commit is the base.
        public static func currentBranch(_ repo: String) -> [String] { ["-C", repo, "rev-parse", "--abbrev-ref", "HEAD"] }
        public static func currentCommit(_ repo: String) -> [String] { ["-C", repo, "rev-parse", "HEAD"] }
        public static func addWorktree(repo: String, branch: String, workdir: String) -> [String] {
            ["-C", repo, "worktree", "add", "-b", branch, workdir, "HEAD"]
        }
        public static func stageAll(_ workdir: String) -> [String] { ["-C", workdir, "add", "-A"] }
        /// Exit 1 when something is staged.
        public static func hasStaged(_ workdir: String) -> [String] { ["-C", workdir, "diff", "--cached", "--quiet"] }
        public static func commit(_ workdir: String, message: String) -> [String] {
            // No signing prompt can be answered from a background task.
            ["-C", workdir, "-c", "commit.gpgsign=false", "commit", "-q", "--no-verify", "-m", message]
        }
        /// What the task changed since it started.
        public static func changes(_ workdir: String, base: String) -> [String] {
            ["-C", workdir, "diff", "--numstat", base + "...HEAD"]
        }
        public static func merge(repo: String, branch: String, message: String) -> [String] {
            ["-C", repo, "-c", "commit.gpgsign=false", "merge", "--no-ff", "-m", message, branch]
        }
        public static func removeWorktree(repo: String, workdir: String) -> [String] {
            ["-C", repo, "worktree", "remove", "--force", workdir]
        }
        public static func deleteBranch(repo: String, branch: String, force: Bool) -> [String] {
            ["-C", repo, "branch", force ? "-D" : "-d", branch]
        }
    }

    public static func commitMessage(_ task: OfficeTask) -> String {
        "\(task.agent.displayName): \(task.title)"
    }
}

/// Runs the git side of a task: its own branch and working copy, the commit of
/// what the agent left, and accept (merge) or throw away. Blocking: call off
/// the main thread.
public enum OfficeWorkspace {
    public struct Output: Equatable, Sendable {
        public var status: Int32
        public var text: String
    }

    public static func git(_ args: [String], timeout: TimeInterval = 120) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return Output(status: -1, text: error.localizedDescription) }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        return Output(status: process.terminationStatus,
                      text: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Creates the task's branch and working copy. A folder outside git is used
    /// as it is (no branch); nil error means ready.
    public static func prepare(_ task: OfficeTask, home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> (task: OfficeTask, error: String?) {
        var task = task
        let root = git(Office.Git.repoRoot(task.folder))
        guard root.status == 0, !root.text.isEmpty else { return (task, nil) }
        let branchName = git(Office.Git.currentBranch(root.text)).text
        let base = branchName == "HEAD" || branchName.isEmpty ? git(Office.Git.currentCommit(root.text)).text : branchName
        let branch = Office.branch(for: task)
        let copy = Office.workdir(for: task, repoRoot: root.text, home: home)
        try? FileManager.default.createDirectory(atPath: (copy as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let added = git(Office.Git.addWorktree(repo: root.text, branch: branch, workdir: copy))
        guard added.status == 0 else { return (task, added.text.isEmpty ? "git worktree" : added.text) }
        task.branch = branch
        task.base = base
        task.workdir = Office.runFolder(folder: task.folder, repoRoot: root.text, workdir: copy)
        return (task, nil)
    }

    /// The repo the task's working copy belongs to.
    static func repo(of task: OfficeTask) -> String? {
        let root = git(Office.Git.repoRoot(task.folder))
        return root.status == 0 && !root.text.isEmpty ? root.text : nil
    }

    static func copyRoot(of task: OfficeTask) -> String? {
        guard let workdir = task.workdir else { return nil }
        let root = git(Office.Git.repoRoot(workdir))
        return root.status == 0 && !root.text.isEmpty ? root.text : nil
    }

    /// Commits whatever the agent changed but didn't commit itself. nil when
    /// done (or nothing to commit, or no working copy); else what git said —
    /// then the work is only in the working copy, which must be kept.
    @discardableResult
    public static func commitLeftovers(_ task: OfficeTask) -> String? {
        guard let copy = copyRoot(of: task) else { return nil }
        let staged = git(Office.Git.stageAll(copy))
        guard staged.status == 0 else { return staged.text.isEmpty ? "git add" : staged.text }
        guard git(Office.Git.hasStaged(copy)).status == 1 else { return nil }
        let committed = git(Office.Git.commit(copy, message: Office.commitMessage(task)))
        return committed.status == 0 ? nil : (committed.text.isEmpty ? "git commit" : committed.text)
    }

    /// A merge, rebase, cherry-pick or revert the user hasn't finished in the
    /// project: nothing may be merged into it then (and nothing aborted).
    static func unfinishedOperation(repo: String) -> String? {
        for (marker, name) in [("MERGE_HEAD", "merge"), ("rebase-merge", "rebase"), ("rebase-apply", "rebase"),
                               ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert")] {
            let path = git(["-C", repo, "rev-parse", "--git-path", marker]).text
            guard !path.isEmpty else { continue }
            let full = path.hasPrefix("/") ? path : (repo as NSString).appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: full) { return name }
        }
        return nil
    }

    /// numstat of the task's branch against where it started (after committing leftovers).
    public static func changes(_ task: OfficeTask) -> String? {
        guard let base = task.base, let copy = copyRoot(of: task) else { return nil }
        let output = git(Office.Git.changes(copy, base: base))
        return output.status == 0 ? output.text : nil
    }

    /// Merges the task's branch into whatever the project has checked out, then
    /// removes the working copy. The error text (a conflict, say) otherwise.
    public static func accept(_ task: OfficeTask) -> String? {
        guard let branch = task.branch, let repo = repo(of: task) else { return nil }
        // The agent's last changes must be on the branch first: otherwise the
        // merge says "up to date" and removing the copy would lose them.
        if let error = commitLeftovers(task) { return "git commit: " + error }
        if let operation = unfinishedOperation(repo: repo) {
            return "the project has an unfinished git \(operation): finish it first"
        }
        let merged = git(Office.Git.merge(repo: repo, branch: branch, message: Office.commitMessage(task)))
        guard merged.status == 0 else {
            // Only a merge this call started is undone (none was going on before).
            if unfinishedOperation(repo: repo) == "merge" { _ = git(["-C", repo, "merge", "--abort"]) }
            return merged.text.isEmpty ? "git merge" : merged.text
        }
        removeCopy(task, repo: repo, branch: branch, force: false)
        return nil
    }

    /// Throws the work away: working copy and branch.
    public static func discard(_ task: OfficeTask) {
        guard let branch = task.branch, let repo = repo(of: task) else { return }
        removeCopy(task, repo: repo, branch: branch, force: true)
    }

    private static func removeCopy(_ task: OfficeTask, repo: String, branch: String, force: Bool) {
        if let copy = copyRoot(of: task) { _ = git(Office.Git.removeWorktree(repo: repo, workdir: copy)) }
        _ = git(Office.Git.deleteBranch(repo: repo, branch: branch, force: force))
    }
}
