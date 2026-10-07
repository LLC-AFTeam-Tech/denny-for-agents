import AgentCore
import SwiftUI
import UniformTypeIdentifiers

/// The round quick-action buttons at the bottom of the open notch.
struct NotchActions {
    var quiet: () -> Void = {}
    var refresh: () -> Void = {}
    var settings: () -> Void = {}
    /// Copy a relay note for this session to the other agent.
    var relay: (String, Bool) -> Void = { _, _ in }
    var dismissRelay: () -> Void = {}
    var undoSnapshot: (SafetyNetNotice) -> Void = { _ in }
    var copyReceipt: (TaskReceipt) -> Void = { _ in }
    var dismissReceipt: () -> Void = {}
    var runTests: (TaskReceipt) -> Void = { _ in }
    var sendTestFailure: () -> Void = {}
    var runReview: (TaskReceipt) -> Void = { _ in }
    var sendReview: () -> Void = {}
    var dismissReview: () -> Void = {}
    var dismissSnapshot: () -> Void = {}
}

struct AgentsNotchView: View {
    @ObservedObject var model: AgentsViewModel
    var onAnswer: (String, ApprovalDecision) -> Void
    var onHover: (Bool) -> Void
    var onOpenFullDenny: () -> Void
    var onDropFiles: ([URL]) -> Void = { _ in }
    var onResetCodex: () -> Void = {}
    var actions = NotchActions()

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(radius: model.mode == .expanded || model.mode == .peek ? 22 : 12)
                .fill(Color.black)
            switch model.mode {
            case .hidden:
                EmptyView()
            case .compact:
                compact
            case .peek:
                VStack(spacing: 0) {
                    Color.clear.frame(height: model.notchHeight)
                    switch model.peek {
                    case .activity(let activity)?:
                        DennyLoopView(files: [DennyClipView.workFile(activity)])
                            .id(activity)
                            .frame(width: 204, height: 136)
                            .padding(.vertical, -10)
                    case .finished(let title, let detail)?:
                        VStack(spacing: 0) {
                            DennyLiveView(reaction: model.reaction)
                                .frame(width: 170, height: 70)
                                .padding(.vertical, 6)
                            Text(title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Text(detail)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                    case .celebration(let agent, let title, let detail)?:
                        VStack(spacing: 2) {
                            DennyClipView(file: DennyClipView.finishFile(agent))
                                .id(title + detail)
                                .frame(width: 200, height: 200)
                            Text(title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Text(detail)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                    case nil:
                        EmptyView()
                    }
                }
            case .expanded:
                expanded
            }
        }
        .onHover(perform: onHover)
        .onDrop(of: [UTType.fileURL], isTargeted: $model.dropTargeted) { providers in
            loadURLs(providers)
            return true
        }
        .animation(.easeInOut(duration: 0.2), value: model.mode)
    }

    private var compact: some View {
        HStack {
            DennyLiveView(reaction: model.reaction)
                .frame(width: 68, height: max(model.notchHeight - 4, 20))
            Spacer()
            CompactReadout(model: model)
        }
        .padding(.horizontal, 10)
        .frame(height: model.notchHeight)
    }

    @ViewBuilder private var expanded: some View {
        let content = ExpandedContent(model: model, onAnswer: onAnswer, onOpenFullDenny: onOpenFullDenny,
                                      onResetCodex: onResetCodex, actions: actions)
        if model.needsScroll {
            ScrollView(.vertical, showsIndicators: true) { content }
        } else {
            content
        }
    }

    private func loadURLs(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty { onDropFiles(urls) }
        }
    }
}

/// The open notch. Kept separate so the controller can measure its height.
struct ExpandedContent: View {
    @ObservedObject var model: AgentsViewModel
    var onAnswer: (String, ApprovalDecision) -> Void
    var onOpenFullDenny: () -> Void
    var onResetCodex: () -> Void = {}
    var actions = NotchActions()
    @ObservedObject var settings = AppSettings.shared
    /// Height measurement only: skip the web view behind the activity scene.
    var measuring = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The row beside the camera: Denny on the left wing, page tabs on the right.
            HStack {
                Group {
                    if measuring { Color.clear } else { DennyLiveView(reaction: model.reaction) }
                }
                .frame(width: 68, height: max(model.notchHeight - 4, 20))
                Spacer()
                CompactReadout(model: model)
            }
            .frame(height: model.notchHeight)
            .padding(.horizontal, -6)
            HStack(spacing: 10) {
                if let activity = model.headerActivity {
                    Group {
                        if measuring {
                            Color.clear
                        } else {
                            DennyLoopView(files: [DennyClipView.workFile(activity)]).id(activity)
                        }
                    }
                    .frame(width: 60, height: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(2)
                }
                Spacer()
            }
            if model.dropTargeted {
                DropZone()
            } else if let message = model.dropMessage {
                DropNotice(message: message, onOpenFullDenny: onOpenFullDenny)
            }
            if let approval = model.approvals.first {
                ApprovalCard(approval: approval, waitingCount: model.approvals.count - 1, onAnswer: onAnswer)
            }
            if let offer = model.relayOffer {
                RelayCard(offer: offer, now: model.now,
                          onCopy: { actions.relay(offer.sessionKey, true) }, onLater: actions.dismissRelay)
            }
            if let receipt = model.receipt, model.now.timeIntervalSince(receipt.finishedAt) < 3600 {
                ReceiptCard(receipt: receipt, testCommand: model.receiptTestCommand,
                            test: model.testRun?.receiptId == receipt.id ? model.testRun : nil, now: model.now,
                            onCopy: { actions.copyReceipt(receipt) }, onHide: actions.dismissReceipt,
                            onRunTests: { actions.runTests(receipt) }, onSendFailure: actions.sendTestFailure,
                            reviewer: model.review?.receiptId == receipt.id ? nil : model.reviewer,
                            onReview: { actions.runReview(receipt) })
                if let review = model.review, review.receiptId == receipt.id {
                    ReviewCard(review: review, now: model.now, onSend: actions.sendReview, onHide: actions.dismissReview)
                }
            }
            if let notice = model.safetyNet, model.now.timeIntervalSince1970 - notice.snapshot.createdAt < 3600 {
                SafetyNetCard(notice: notice, onUndo: { actions.undoSnapshot(notice) }, onHide: actions.dismissSnapshot)
            }
            if model.page == .stats, StatsPage.hasContent(model.summary, visible: model.visibleCards) {
                StatsPage(summary: model.summary, period: $model.period, visible: model.visibleCards)
            } else if !model.summary.agentsSeen.isEmpty {
                StatsGrid(summary: model.summary, period: $model.period, visible: model.visibleCards,
                          workingAgents: model.workingAgents, now: model.now,
                          canResetCodex: model.canResetCodex, resettingCodex: model.resettingCodex,
                          onResetCodex: onResetCodex)
            }
            if model.page == .overview || !StatsPage.hasContent(model.summary, visible: model.visibleCards) {
                ForEach(model.sessions.prefix(3)) { session in
                    SessionRow(session: session, onRelay: session.lastPrompt == nil ? nil : { actions.relay(session.id, false) })
                }
            }
            Button(action: onOpenFullDenny) {
                Text(L.fullDenny)
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var title: String {
        switch model.mood {
        case .idle where model.tightestLimit != nil:
            let limit = model.tightestLimit!
            return L.limitTitle(limit.agent, used: limit.window.percent)
        case .idle: return L.idleTitle
        case .working: return L.workingTitle
        case .needsYou: return L.needsYouTitle
        }
    }

    private var subtitle: String {
        if !model.serverRunning { return L.serverDown }
        if !model.hooksInstalled { return L.noHooks }
        if model.mood == .idle, let limit = model.tightestLimit {
            let left = (limit.window.resetsAt ?? 0) - model.now.timeIntervalSince1970
            return L.limitDetail(limit.window, resetsIn: left > 0 ? Fmt.countdown(left) : nil)
        }
        if model.sessions.isEmpty { return L.noSessions }
        return model.sessions.first?.currentStep ?? ""
    }
}

/// A round button like the ones around Vorssaint's island; the title is a tooltip.
struct RoundButton: View {
    let symbol: String
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(selected ? .black : .white.opacity(0.8))
                .frame(width: 28, height: 28)
                .background(Circle().fill(selected ? Color.white.opacity(0.9) : Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct PageTabs: View {
    @Binding var page: NotchPage

    var body: some View {
        HStack(spacing: 2) {
            tab(.overview, symbol: "square.grid.2x2", title: L.pageOverview)
            tab(.stats, symbol: "chart.bar.xaxis", title: L.pageStats)
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private func tab(_ target: NotchPage, symbol: String, title: String) -> some View {
        Button {
            page = target
            ViewSettings.page = target
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(page == target ? .white : .white.opacity(0.45))
                .frame(width: 26, height: 18)
                .background(Capsule().fill(page == target ? Color.white.opacity(0.16) : .clear))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// "Claude hit its limit until 18:40 — hand the task to Codex?"
struct RelayCard: View {
    let offer: RelayOffer
    let now: Date
    let onCopy: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentMark(agent: offer.from, size: 16)
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.5))
                AgentMark(agent: offer.to, size: 16)
                Text(L.relayTitle(offer.from, until: offer.resetsAt.flatMap { $0 > now.timeIntervalSince1970 ? Fmt.time(Date(timeIntervalSince1970: $0)) : nil }))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            Text(L.relayBody(offer.to))
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.7))
            HStack(spacing: 8) {
                NotchButton(title: L.relayCopy(offer.to), color: offer.to.tint, prominent: true, action: onCopy)
                NotchButton(title: L.relayLater, color: .gray, action: onLater)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).stroke(offer.to.tint.opacity(0.7), lineWidth: 1))
    }
}

/// What the last task changed and cost — made to be screenshotted.
struct ReceiptCard: View {
    let receipt: TaskReceipt
    var testCommand: String?
    var test: TestRun?
    var now = Date()
    let onCopy: () -> Void
    let onHide: () -> Void
    var onRunTests: () -> Void = {}
    var onSendFailure: () -> Void = {}
    var reviewer: AgentKind?
    var onReview: () -> Void = {}

    static func lines(_ receipt: TaskReceipt) -> [String] {
        var files = L.receiptFiles(receipt.files.count)
        if let added = receipt.added, let removed = receipt.removed { files += " (" + L.receiptLines(added, removed) + ")" }
        var result = [files, L.receiptCommands(receipt.commands)]
        if receipt.tokens > 0 {
            var tokens = L.receiptTokens(Fmt.tokens(receipt.tokens))
            if let cost = receipt.cost { tokens += " · " + L.receiptCost(Fmt.cost(cost)) }
            result.append(tokens)
        }
        return result
    }

    /// One line for the clipboard.
    static func text(_ receipt: TaskReceipt) -> String {
        var parts = ["🧾 " + receipt.agent.displayName, receipt.projectName]
        if let duration = receipt.duration { parts.append(Fmt.countdown(duration)) }
        return (parts + lines(receipt)).joined(separator: " · ") + " — " + L.receiptSignature
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AgentMark(agent: receipt.agent, size: 14)
                Text(L.receiptTitle).font(.system(size: 12, weight: .semibold))
                Text(receipt.projectName).font(.system(size: 12)).foregroundColor(.white.opacity(0.6)).lineLimit(1)
                Spacer()
                if let duration = receipt.duration {
                    Label(Fmt.countdown(duration), systemImage: "timer")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            ForEach(Self.lines(receipt), id: \.self) { line in
                Text(line).font(.system(size: 11, design: .rounded)).foregroundColor(.white.opacity(0.85))
            }
            if !receipt.files.isEmpty {
                Text(receipt.files.prefix(4).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                     + (receipt.files.count > 4 ? " …" : ""))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let test {
                testLine(test)
            }
            HStack(spacing: 8) {
                if let test, case .failed = test.state {
                    NotchButton(title: L.testsSendToAgent, color: .red, prominent: true, action: onSendFailure)
                } else if test == nil, testCommand != nil {
                    NotchButton(title: L.testsRun, color: .green, action: onRunTests)
                        .help(testCommand ?? "")
                }
                if let reviewer {
                    NotchButton(title: L.reviewButton(reviewer), color: reviewer.tint, action: onReview)
                }
            }
            HStack(spacing: 8) {
                NotchButton(title: L.receiptCopy, color: receipt.agent.tint, prominent: true, action: onCopy)
                NotchButton(title: L.receiptHide, color: .gray, action: onHide)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).stroke(receipt.agent.tint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    @ViewBuilder private func testLine(_ test: TestRun) -> some View {
        let duration = Fmt.countdown(test.duration ?? now.timeIntervalSince(test.startedAt))
        switch test.state {
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(L.testsRunning(test.command)).lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.8))
        case .passed:
            Text(L.testsPassed(duration)).font(.system(size: 11, weight: .semibold)).foregroundColor(.green)
        case .failed:
            Text(L.testsFailed(duration)).font(.system(size: 11, weight: .semibold)).foregroundColor(.red)
        case .unavailable(let reason):
            Text(reason).font(.system(size: 11)).foregroundColor(.white.opacity(0.6))
        }
    }
}

/// The other agent's read-only review of the task's changes.
struct ReviewCard: View {
    let review: ReviewRun
    let now: Date
    let onSend: () -> Void
    let onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AgentMark(agent: review.reviewer, size: 14)
                switch review.state {
                case .running:
                    ProgressView().controlSize(.mini)
                    Text(L.reviewRunning(review.reviewer, Fmt.countdown(now.timeIntervalSince(review.startedAt))))
                case .done(_, let findings):
                    Text(findings == 0 ? L.reviewClean(review.reviewer) : L.reviewFindings(review.reviewer, findings))
                case .failed(let reason):
                    Text(L.reviewFailed(review.reviewer, reason)).foregroundColor(.orange)
                }
                Spacer()
            }
            .font(.system(size: 12, weight: .semibold))
            if case .done(let text, _) = review.state {
                ScrollView {
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }
            HStack(spacing: 8) {
                if case .done(_, let findings) = review.state, findings > 0 {
                    NotchButton(title: L.reviewSend(review.author), color: review.author.tint, prominent: true, action: onSend)
                }
                if review.state != .running {
                    NotchButton(title: L.receiptHide, color: .gray, action: onHide)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).stroke(review.reviewer.tint.opacity(0.6), lineWidth: 1))
    }
}

/// "Safety net": files were saved before a destructive command; one click
/// puts them back (or copies the command for a server).
struct SafetyNetCard: View {
    let notice: SafetyNetNotice
    let onUndo: () -> Void
    let onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lifepreserver")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.green)
                Text(L.safetyCardTitle)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(Fmt.time(Date(timeIntervalSince1970: notice.snapshot.createdAt)))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
            Text(notice.snapshot.command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(notice.host.map(L.safetyOnServer) ?? L.safetyCardBody)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.6))
            HStack(spacing: 8) {
                NotchButton(title: notice.host == nil ? L.safetyUndo : L.safetyCopyCommand, color: .green,
                            prominent: true, action: onUndo)
                NotchButton(title: L.safetyHide, color: .gray, action: onHide)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).stroke(Color.green.opacity(0.6), lineWidth: 1))
    }
}

struct DropZone: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 16, weight: .medium))
            Text(L.dropHere)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(.white.opacity(0.85))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundColor(.white.opacity(0.4)))
    }
}

struct DropNotice: View {
    let message: DropMessage
    var onOpenFullDenny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(message.title, systemImage: "doc.on.clipboard")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
            if let warning = message.warning {
                Text(warning)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
            Button(action: onOpenFullDenny) {
                Text(L.shelfInFullDenny)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

/// Square top edge flush with the screen, rounded bottom corners -- the
/// same silhouette as the camera notch, just bigger.
struct NotchShape: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The right wing of the closed notch: a turn timer while an agent works,
/// the waiting count when it needs you, the tightest limit at rest.
struct CompactReadout: View {
    @ObservedObject var model: AgentsViewModel

    var body: some View {
        if model.mood == .needsYou {
            StatusBadge(mood: .needsYou, count: model.approvals.count)
        } else if model.mood == .working, model.readout == .timer, let turn = model.currentTurn {
            HStack(spacing: 5) {
                Circle().fill(turn.agent.tint).frame(width: 6, height: 6)
                TimelineView(.periodic(from: turn.start, by: 1)) { context in
                    Text(Fmt.clock(context.date.timeIntervalSince(turn.start)))
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundColor(.white)
                        .fixedSize()
                }
            }
        } else if model.mood == .working, model.readout == .timer || model.restingLimit == nil {
            StatusBadge(mood: .working, count: 0)
        } else if let limit = model.restingLimit {
            HStack(spacing: 5) {
                LimitRing(fraction: limit.window.percent / 100, tint: limitTint(limit.agent, percent: limit.window.percent))
                    .frame(width: 14, height: 14)
                Text("\(Int(limit.window.percent.rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(.white)
                    .fixedSize()
            }
        } else {
            StatusBadge(mood: .idle, count: 0)
        }
    }
}

struct LimitRing: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        // Inset by half the line so the stroke stays inside the frame.
        ZStack {
            Circle().inset(by: 1.25).stroke(Color.white.opacity(0.18), lineWidth: 2.5)
            Circle()
                .inset(by: 1.25)
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(0.5)
    }
}

struct StatusBadge: View {
    let mood: AgentMood
    let count: Int

    var body: some View {
        switch mood {
        case .needsYou:
            Text(count > 0 ? "\(count)" : "!")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.black)
                .frame(minWidth: 18, minHeight: 18)
                .background(Circle().fill(Color.orange))
        case .working:
            ProgressView()
                .controlSize(.small)
                .colorScheme(.dark)
        case .idle:
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
        }
    }
}

extension RiskLevel {
    var color: Color {
        switch self {
        case .safe: return .green
        case .caution: return .yellow
        case .danger: return .orange
        case .critical: return .red
        }
    }

    var symbol: String {
        switch self {
        case .safe: return "checkmark.shield.fill"
        case .caution: return "exclamationmark.shield.fill"
        case .danger: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }
}

/// Denny's verdict on the request: a colored badge and plain-word reasons.
struct RiskBanner: View {
    let risk: RiskAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(L.riskLevel(risk.level), systemImage: risk.level.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(risk.level.color)
            ForEach(Array(risk.reasons.prefix(2).enumerated()), id: \.offset) { _, reason in
                Text(L.riskReason(reason))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(risk.level.color.opacity(0.14)))
    }
}

struct ApprovalCard: View {
    let approval: PendingApproval
    let waitingCount: Int
    var onAnswer: (String, ApprovalDecision) -> Void

    private var risky: Bool { approval.risk.level >= .danger }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(approval.agent.displayName) · \(approval.projectName)\(approval.host.map { " · \($0)" } ?? "") \(L.wantsTo):")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.6))
            Text(approval.summary)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
            if let detail = approval.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
            }
            if approval.risk.level > .safe || !approval.risk.reasons.isEmpty {
                RiskBanner(risk: approval.risk)
            }
            HStack(spacing: 8) {
                // When it looks dangerous, Deny comes first and Allow steps back.
                if risky {
                    NotchButton(title: L.deny, color: .red, prominent: true) { onAnswer(approval.id, .deny) }
                    NotchButton(title: L.allow, color: .gray) { onAnswer(approval.id, .allow) }
                } else {
                    NotchButton(title: L.allow, color: .green, prominent: true) { onAnswer(approval.id, .allow) }
                    NotchButton(title: L.deny, color: .red) { onAnswer(approval.id, .deny) }
                }
                NotchButton(title: L.askThere, color: .gray) { onAnswer(approval.id, .ask) }
            }
            if waitingCount > 0 {
                Text(L.moreApprovals(waitingCount))
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).stroke((risky ? approval.risk.level.color : Color.orange).opacity(0.7),
                                                             lineWidth: risky ? 1.5 : 1))
    }
}

struct NotchButton: View {
    let title: String
    let color: Color
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(prominent ? 0.6 : 0.25)))
        }
        .buttonStyle(.plain)
    }
}

struct SessionRow: View {
    let session: AgentSession
    var onRelay: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(session.projectName) · \(session.agent.displayName)\(session.host.map { " · \($0)" } ?? "")")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(session.currentStep ?? "")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer()
            if let onRelay {
                Button(action: onRelay) {
                    Label(Relay.other(session.agent).displayName, systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(L.relayHandoff(Relay.other(session.agent)))
            }
        }
    }

    private var color: Color {
        switch session.status {
        case .working: return .blue
        case .waitingApproval, .waitingInput: return .orange
        case .finished: return .green
        case .idle: return .gray
        }
    }
}
