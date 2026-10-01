import AgentCore
import SwiftUI

extension AgentKind {
    /// One color per agent everywhere: cards, meters, dots.
    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.87, green: 0.50, blue: 0.36)
        case .codex: return Color(red: 0.47, green: 0.62, blue: 1.0)
        }
    }
}

func limitTint(_ agent: AgentKind, percent: Double) -> Color {
    if percent >= 95 { return .red }
    if percent >= 80 { return .orange }
    return agent.tint
}

/// Two cards a row: each agent's limits, then spending and "now".
struct StatsGrid: View {
    let summary: UsageSummary
    @Binding var period: UsagePeriod
    let workingAgents: Set<AgentKind>
    let now: Date
    var canResetCodex = false
    var resettingCodex = false
    var onResetCodex: () -> Void = {}
    @State private var rowHeights: [Int: CGFloat] = [:]

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(summary.agentsSeen, id: \.self) { agent in
                    LimitsCard(agent: agent, limits: summary.limits[agent], now: now,
                               resets: summary.resets[agent], canReset: canResetCodex && agent == .codex,
                               resetting: resettingCodex, onReset: onResetCodex)
                }
            }
            .environment(\.statsRow, 0)
            HStack(alignment: .top, spacing: 8) {
                SpendCard(spend: summary.spend[period] ?? UsageSummary.Spend(), period: $period)
                NowCard(summary: summary, workingAgents: workingAgents, now: now)
            }
            .environment(\.statsRow, 1)
            if summary.activeDays > 0 {
                ActivityCard(summary: summary)
            }
        }
        .environment(\.statsRowHeights, rowHeights)
        .onPreferenceChange(RowHeightKey.self) { rowHeights = $0 }
    }
}

/// Cards in a row share the tallest card's height. Each card reports its
/// natural height and pads up to the row's; nothing grows unbounded, so the
/// notch can still measure how tall it needs to be.
struct RowHeightKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: max)
    }
}

private struct StatsRowKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

private struct StatsRowHeightsKey: EnvironmentKey {
    static let defaultValue: [Int: CGFloat] = [:]
}

extension EnvironmentValues {
    var statsRow: Int? {
        get { self[StatsRowKey.self] }
        set { self[StatsRowKey.self] = newValue }
    }

    var statsRowHeights: [Int: CGFloat] {
        get { self[StatsRowHeightsKey.self] }
        set { self[StatsRowHeightsKey.self] = newValue }
    }
}

struct StatsCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.statsRow) private var row
    @Environment(\.statsRowHeights) private var rowHeights

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: RowHeightKey.self, value: row.map { [$0: proxy.size.height] } ?? [:])
            })
            .frame(minHeight: row.flatMap { rowHeights[$0] }, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

struct CardHeader<Accessory: View>: View {
    let title: String
    var agent: AgentKind?
    var symbol: String = "circle"
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 5) {
            if let agent {
                Circle().fill(agent.tint).frame(width: 7, height: 7)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
            }
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 4)
            accessory
        }
    }
}

struct PlanChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(0.16)))
    }
}

/// A thin capsule. The white tick marks where you'd be if the allowance
/// were spent evenly across the window; a fill past it is ahead of pace.
struct LimitMeter: View {
    let fraction: Double
    let tint: Color
    var pace: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.13))
                Capsule()
                    .fill(tint)
                    .frame(width: max(fraction > 0 ? 5 : 0, proxy.size.width * min(1, max(0, fraction))))
                if let pace, pace > 0.02, pace < 0.98 {
                    RoundedRectangle(cornerRadius: 0.75)
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 1.5, height: 10)
                        .offset(x: proxy.size.width * pace - 0.75)
                }
            }
        }
        .frame(height: 5)
        .padding(.vertical, 2.5)
    }
}

struct LimitsCard: View {
    let agent: AgentKind
    let limits: UsageReport.Limits?
    let now: Date
    var resets: UsageReport.Resets?
    var canReset = false
    var resetting = false
    var onReset: () -> Void = {}

    private var stale: Bool {
        guard let limits else { return false }
        return now.timeIntervalSince1970 - limits.observedAt > 30 * 60
    }

    var body: some View {
        StatsCard {
            CardHeader(title: agent == .claude ? "Claude" : "Codex", agent: agent) {
                if let plan = limits?.plan { PlanChip(text: plan, tint: agent.tint) }
            }
            if let windows = limits?.windows, !windows.isEmpty {
                ForEach(Array(windows.prefix(3).enumerated()), id: \.offset) { _, window in
                    row(window)
                }
                .opacity(stale ? 0.6 : 1)
                if stale, let observed = limits?.observedAt {
                    Text(L.updated(Fmt.relative(Date(timeIntervalSince1970: observed), now: now)))
                        .font(.system(size: 9.5))
                        .foregroundColor(.white.opacity(0.45))
                }
            } else {
                Text(L.limitsLater)
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(2)
            }
            if let resets {
                resetsRow(resets)
            }
        }
    }

    private func resetsRow(_ resets: UsageReport.Resets) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 9, weight: .semibold))
            Text(resetsText(resets))
                .font(.system(size: 9.5))
                .lineLimit(1)
            Spacer(minLength: 2)
            if canReset && resets.available > 0 {
                Button(action: onReset) {
                    Text(resetting ? L.resetting : L.useReset)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(agent.tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(agent.tint.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .disabled(resetting)
            }
        }
        .foregroundColor(.white.opacity(0.55))
    }

    private func resetsText(_ resets: UsageReport.Resets) -> String {
        var text = L.resetsLine(resets.available)
        if resets.available > 0, let expires = resets.nextExpiresAt, expires > now.timeIntervalSince1970 {
            text += " · " + L.expiresIn(Fmt.countdown(expires - now.timeIntervalSince1970))
        }
        return text
    }

    private func row(_ window: UsageReport.Window) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(L.windowName(window))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                if let resets = window.resetsAt, resets > now.timeIntervalSince1970 {
                    Text("⏱ " + Fmt.countdown(resets - now.timeIntervalSince1970))
                        .font(.system(size: 9.5))
                        .foregroundColor(.white.opacity(0.5))
                }
                Spacer(minLength: 2)
                Text("\(Int(window.percent.rounded()))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            }
            LimitMeter(fraction: window.percent / 100, tint: limitTint(agent, percent: window.percent),
                       pace: pace(window))
        }
    }

    private func pace(_ window: UsageReport.Window) -> Double? {
        guard let resets = window.resetsAt else { return nil }
        let length: Double = window.kind == "session" ? 5 * 3600 : 7 * 86400
        let left = resets - now.timeIntervalSince1970
        guard left > 0, left < length else { return nil }
        return 1 - left / length
    }
}

struct SpendCard: View {
    let spend: UsageSummary.Spend
    @Binding var period: UsagePeriod

    var body: some View {
        StatsCard {
            CardHeader(title: L.spending, symbol: "dollarsign.circle") {
                Button(action: cycle) {
                    Text(L.period(period) + " ▾")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(showsTokensOnly ? Fmt.tokens(spend.tokens) : (spend.fullyPriced ? "" : "≥ ") + Fmt.cost(spend.cost))
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                Text(showsTokensOnly ? L.tokensWord : L.apiValue)
                    .font(.system(size: 9.5))
                    .foregroundColor(.white.opacity(0.5))
            }
            Text(footer)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(1)
        }
    }

    /// Only unpriced models (Codex) were used: a dollar figure would read $0.
    private var showsTokensOnly: Bool {
        !spend.fullyPriced && spend.cost < 0.01
    }

    private var footer: String {
        var parts = [showsTokensOnly ? L.noPrice : L.tokens(Fmt.tokens(spend.tokens))]
        if let share = spend.cacheShare { parts.append(L.fromCache(Int((share * 100).rounded()))) }
        return parts.joined(separator: " · ")
    }

    private func cycle() {
        let all = UsagePeriod.allCases
        period = all[(all.firstIndex(of: period)! + 1) % all.count]
    }
}

struct NowCard: View {
    let summary: UsageSummary
    let workingAgents: Set<AgentKind>
    let now: Date

    var body: some View {
        StatsCard {
            CardHeader(title: L.now, symbol: "waveform") { EmptyView() }
            ForEach(summary.agentsSeen, id: \.self) { agent in
                HStack(spacing: 6) {
                    Circle()
                        .fill(workingAgents.contains(agent) ? agent.tint : agent.tint.opacity(0.35))
                        .frame(width: 6, height: 6)
                    Text(agent == .claude ? "Claude" : "Codex")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer(minLength: 2)
                    Text(status(agent))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
            if let today = summary.spend[.today], today.cost >= 0.01 {
                Text(L.todayTotal((today.fullyPriced ? "" : "≥ ") + Fmt.cost(today.cost)))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
    }

    private func status(_ agent: AgentKind) -> String {
        if workingAgents.contains(agent) { return L.workingNow }
        guard let last = summary.lastActivity[agent] else { return "—" }
        return Fmt.relative(last, now: now)
    }
}

/// 13 weeks, a column per week, brighter cells for busier days.
struct ActivityCard: View {
    let summary: UsageSummary

    private let cell: CGFloat = 11
    private let gap: CGFloat = 3

    var body: some View {
        StatsCard {
            CardHeader(title: L.activity, symbol: "square.grid.3x3.fill") {
                if summary.streak > 0 {
                    Text("🔥 " + L.streak(summary.streak))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            HStack(alignment: .top, spacing: 14) {
                grid
                VStack(alignment: .leading, spacing: 4) {
                    stat(L.activeDays, "\(summary.activeDays)")
                    if let busiest = summary.busiestDay {
                        stat(L.busiestDay, Fmt.day(busiest.start) + " · " + Fmt.tokens(busiest.tokens))
                    }
                }
            }
        }
    }

    private var grid: some View {
        let weeks = stride(from: 0, to: summary.days.count, by: 7).map { Array(summary.days[$0..<min($0 + 7, summary.days.count)]) }
        let levels = thresholds()
        return HStack(alignment: .top, spacing: gap) {
            ForEach(weeks.indices, id: \.self) { column in
                VStack(spacing: gap) {
                    ForEach(weeks[column].indices, id: \.self) { row in
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(color(for: weeks[column][row].tokens, levels: levels))
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundColor(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        }
    }

    /// Quartiles of the active days, so one huge day doesn't wash out the rest.
    private func thresholds() -> [Int] {
        let values = summary.days.map(\.tokens).filter { $0 > 0 }.sorted()
        guard !values.isEmpty else { return [] }
        return [0.25, 0.5, 0.75].map { values[min(values.count - 1, Int(Double(values.count) * $0))] }
    }

    private func color(for tokens: Int, levels: [Int]) -> Color {
        guard tokens > 0 else { return Color.white.opacity(0.08) }
        let level = levels.filter { tokens >= $0 }.count
        return AgentKind.claude.tint.opacity([0.35, 0.55, 0.75, 1.0][min(level, 3)])
    }
}

enum Fmt {
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L.language.localeIdentifier)
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: date)
    }

    static func cost(_ value: Double) -> String {
        String(format: value >= 100 ? "$%.0f" : "$%.2f", value)
    }

    static func tokens(_ value: Int) -> String {
        let number = Double(value)
        if number >= 1_000_000_000 { return String(format: "%.1fB", number / 1_000_000_000) }
        if number >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
        if number >= 1_000 { return String(format: "%.0fK", number / 1_000) }
        return "\(value)"
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func countdown(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        if days > 0 { return L.daysHours(days, hours) }
        if hours > 0 { return L.hoursMinutes(hours, mins) }
        return L.minutesOnly(max(mins, 1))
    }

    static func relative(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        if minutes < 1 { return L.justNow }
        if minutes < 60 { return L.ago(L.minutesOnly(minutes)) }
        let hours = minutes / 60
        if hours < 24 { return L.ago(L.hoursOnly(hours)) }
        let days = hours / 24
        if days < 30 { return L.ago(L.daysOnly(days)) }
        return L.ago(L.monthsOnly(days / 30))
    }
}
