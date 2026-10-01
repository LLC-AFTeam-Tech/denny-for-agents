import AgentCore
import SwiftUI
import UniformTypeIdentifiers

struct AgentsNotchView: View {
    @ObservedObject var model: AgentsViewModel
    let face: DennyFaceViewModel
    var onAnswer: (String, ApprovalDecision) -> Void
    var onHover: (Bool) -> Void
    var onOpenFullDenny: () -> Void
    var onDropFiles: ([URL]) -> Void = { _ in }
    var onResetCodex: () -> Void = {}

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
                    if let activity = model.peekActivity {
                        DennyActivityView(activity: activity, reduceMotion: false)
                            .frame(width: 168, height: 112)
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
            DennyRobotFaceView(model: face)
                .frame(width: 42, height: max(model.notchHeight - 4, 20))
            Spacer()
            CompactReadout(model: model)
        }
        .padding(.horizontal, 10)
        .frame(height: model.notchHeight)
    }

    private var expanded: some View {
        ExpandedContent(model: model, face: face, onAnswer: onAnswer, onOpenFullDenny: onOpenFullDenny,
                        onResetCodex: onResetCodex)
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
    let face: DennyFaceViewModel
    var onAnswer: (String, ApprovalDecision) -> Void
    var onOpenFullDenny: () -> Void
    var onResetCodex: () -> Void = {}
    /// Height measurement only: skip the web view behind the activity scene.
    var measuring = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: max(model.notchHeight - 8, 0))
            HStack(spacing: 10) {
                if let activity = model.headerActivity {
                    Group {
                        if measuring { Color.clear } else { DennyActivityView(activity: activity, reduceMotion: false) }
                    }
                    .frame(width: 84, height: 56)
                } else {
                    DennyRobotFaceView(model: face)
                        .frame(width: 66, height: 50)
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
            if !model.summary.agentsSeen.isEmpty {
                StatsGrid(summary: model.summary, period: $model.period,
                          workingAgents: model.workingAgents, now: model.now,
                          canResetCodex: model.canResetCodex, resettingCodex: model.resettingCodex,
                          onResetCodex: onResetCodex)
            }
            ForEach(model.sessions.prefix(3)) { session in
                SessionRow(session: session)
            }
            Button(action: onOpenFullDenny) {
                Text(L.fullDenny)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
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
        } else if model.mood == .working, let turn = model.currentTurn {
            HStack(spacing: 5) {
                Circle().fill(turn.agent.tint).frame(width: 6, height: 6)
                TimelineView(.periodic(from: turn.start, by: 1)) { context in
                    Text(Fmt.clock(context.date.timeIntervalSince(turn.start)))
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundColor(.white)
                        .fixedSize()
                }
            }
        } else if model.mood == .working {
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

struct ApprovalCard: View {
    let approval: PendingApproval
    let waitingCount: Int
    var onAnswer: (String, ApprovalDecision) -> Void

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
            HStack(spacing: 8) {
                NotchButton(title: L.allow, color: .green) { onAnswer(approval.id, .allow) }
                NotchButton(title: L.deny, color: .red) { onAnswer(approval.id, .deny) }
                NotchButton(title: L.askThere, color: .gray) { onAnswer(approval.id, .ask) }
            }
            if waitingCount > 0 {
                Text(L.moreApprovals(waitingCount))
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.6), lineWidth: 1))
    }
}

struct NotchButton: View {
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.35)))
        }
        .buttonStyle(.plain)
    }
}

struct SessionRow: View {
    let session: AgentSession

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
