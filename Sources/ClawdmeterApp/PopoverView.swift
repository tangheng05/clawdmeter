import ClawdmeterCore
import SwiftUI

struct PopoverView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            LimitsSection(limits: model.currentLimits, dailyUsage: model.dailyUsage)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            Divider()
            SessionsSection(sessions: model.sessions, onSelect: model.focus)
            if !(model.installStatus.statusline && model.installStatus.hooks) || model.installError != nil {
                Divider()
                SetupBanner(model: model)
            }
            if model.updater.available != nil || model.updater.status != .idle {
                Divider()
                UpdateBanner(updater: model.updater)
            }
            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ClawdView(mood: model.mood, sweating: model.sweating, animate: model.animate)
            Text(headline).font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var headline: String {
        let s = model.sessions
        let waiting = s.filter { $0.state == .waiting }.count
        let working = s.filter { $0.state == .working }.count
        if s.isEmpty { return "No sessions running" }
        if waiting > 0 { return waiting == 1 ? "A session needs you" : "\(waiting) sessions need you" }
        if working > 0 { return working == 1 ? "Claude is working" : "\(working) sessions working" }
        return s.count == 1 ? "Claude is idle" : "All \(s.count) sessions idle"
    }

    private var footer: some View {
        HStack {
            Button {
                model.openSettings?()
            } label: {
                Label("Settings", systemImage: "gearshape").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",")
            .help("Settings (⌘,)")
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

/// Neutral until a limit gets close, so color always means "watch out".
func usageColor(_ used: Double) -> Color {
    if used >= 90 { return .red }
    if used >= 70 { return .orange }
    return .primary
}

private struct LimitsSection: View {
    let limits: RateLimits?
    let dailyUsage: [UsageHistory.Day]

    var body: some View {
        if let limits {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 20) {
                    Meter(title: "5-hour", window: limits.fiveHour, resetStyle: .countdown, period: 5 * 3600)
                    Meter(title: "Weekly", window: limits.sevenDay, resetStyle: .clock, period: 7 * 86_400)
                }
                WeekChart(dailyUsage: dailyUsage)
                if limits.isStale() {
                    Text("Last updated \(limits.updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .opacity(limits.isStale() ? 0.6 : 1)
        } else {
            Text("Usage limits show up after your next Claude Code message. They're only available when you sign in with a Claude subscription.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Meter: View {
    enum ResetStyle { case countdown, clock }

    let title: String
    let window: LimitWindow?
    let resetStyle: ResetStyle
    let period: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(window.map { "\(Int($0.usedPercentage.rounded(.down)))%" } ?? "–")
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                .foregroundStyle(usageColor(window?.usedPercentage ?? 0))
                .contentTransition(.numericText())
            bar
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 3) {
                    Text(resetText(now: context.date))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    forecastText(now: context.date)
                        .help("Estimate based on your average pace since this window started")
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bar: some View {
        let fraction = min(max((window?.usedPercentage ?? 0) / 100, 0), 1)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(usageColor(window?.usedPercentage ?? 0).opacity(0.85))
                    .frame(width: max(geo.size.width * fraction, fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: 4)
    }

    @ViewBuilder
    private func forecastText(now: Date) -> some View {
        switch window.flatMap({ Pace.forecast($0, period: period, now: now) }) {
        case .hitsLimit(let at):
            Text("Runs out \(resetStyle == .countdown ? at.formatted(date: .omitted, time: .shortened) : dayAndTime(at))")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
        case .onTrack(let projected):
            Text("On track for \(projected)% at reset")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    private func resetText(now: Date) -> String {
        guard let reset = window?.resetsAt, reset > now else { return " " }
        switch resetStyle {
        case .countdown:
            let minutes = Int(reset.timeIntervalSince(now) / 60)
            return minutes >= 60 ? "resets in \(minutes / 60)h \(minutes % 60)m" : "resets in \(max(minutes, 1))m"
        case .clock:
            return "resets \(dayAndTime(reset))"
        }
    }
}

private struct SessionsSection: View {
    let sessions: [Session]
    let onSelect: (Session) -> Void

    var body: some View {
        if sessions.isEmpty {
            Text("Start `claude` in a terminal and it shows up here.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        } else {
            let list = VStack(spacing: 0) {
                ForEach(sessions) { session in
                    SessionRow(session: session) { onSelect(session) }
                }
            }
            .padding(.vertical, 4)
            // A fixed height keeps the popover from resizing (and drifting) after it opens.
            if sessions.count > 6 {
                ScrollView { list }.frame(height: 300)
            } else {
                list
            }
        }
    }
}

private struct SessionRow: View {
    let session: Session
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) { content }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Go to this session")
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if let branch = session.branch {
                        Text(branch).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if session.state != .idle {
                TimelineView(.periodic(from: session.since, by: 1)) { context in
                    Text(elapsed(from: session.since, to: context.date))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .padding(.horizontal, 6)
    }

    private var dotColor: Color {
        switch session.state {
        case .waiting: .yellow
        case .working: Color(nsColor: MenuBarIcon.claudeOrange)
        case .idle: Color.secondary.opacity(0.4)
        }
    }

    private var detail: String {
        switch session.state {
        case .waiting:
            session.waitingFor.flatMap { $0 == "dialog open" ? nil : "Needs you: \($0)" } ?? "Needs you"
        case .working: session.tool.map { "Running \($0)" } ?? "Thinking"
        case .idle:
            Date.now.timeIntervalSince(session.since) >= 60
                ? "Idle for \(elapsed(from: session.since, to: .now, coarse: true))" : "Idle"
        }
    }
}

private struct UpdateBanner: View {
    let updater: Updater
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(detailColor) }
            }
            Spacer(minLength: 8)
            action
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var title: String {
        switch updater.status {
        case .checking: "Checking for updates…"
        case .upToDate: "You're on the latest version"
        case .checkFailed: "Couldn't check for updates"
        case .installing: "Updating…"
        case .failed: "The update didn't finish"
        case .idle: "Version \(updater.available?.version ?? "") is available"
        }
    }

    private var detail: String? {
        switch updater.status {
        case .failed(let message), .checkFailed(let message): message
        case .upToDate: "Clawdmeter \(updater.currentVersion)"
        case .idle where updater.viaHomebrew: "Run brew upgrade clawdmeter in Terminal"
        case .idle: "You have \(updater.currentVersion)"
        default: nil
        }
    }

    private var detailColor: Color {
        if case .failed = updater.status { return .red }
        return .secondary
    }

    @ViewBuilder private var action: some View {
        switch updater.status {
        case .installing, .checking:
            ProgressView().controlSize(.small)
        case .idle where updater.available != nil:
            HStack(spacing: 6) {
                Button("What's new") { updater.openReleasePage() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                if updater.viaHomebrew {
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew upgrade clawdmeter", forType: .string)
                        copied = true
                    }
                    .controlSize(.small)
                } else {
                    Button("Update") { Task { await updater.install() } }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            }
        case .failed where updater.available != nil:
            Button("Download") { updater.openReleasePage() }
                .controlSize(.small)
        default:
            EmptyView()
        }
    }
}

private struct SetupBanner: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.installError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            } else {
                Text("Connect to Claude Code to see tool activity and usage limits.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button("Connect") { model.install() }.controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

func elapsed(from start: Date, to end: Date, coarse: Bool = false) -> String {
    let seconds = max(0, Int(end.timeIntervalSince(start)))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return coarse ? "\(seconds / 60)m" : "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s" }
    return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
}

/// Weekly-limit usage per day for the last week; hidden until there's history.
private struct WeekChart: View {
    let dailyUsage: [UsageHistory.Day]

    var body: some View {
        if dailyUsage.filter({ $0.amount > 0 }).count >= 2 {
            let peak = max(dailyUsage.map(\.amount).max() ?? 1, 1)
            VStack(alignment: .leading, spacing: 6) {
            Text("Last 7 days").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(dailyUsage.enumerated()), id: \.offset) { index, day in
                    let today = index == dailyUsage.count - 1
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.primary.opacity(today ? 0.75 : 0.25))
                            .frame(width: 16, height: max(2, 28 * day.amount / peak))
                            .frame(height: 28, alignment: .bottom)
                        Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 9, weight: today ? .semibold : .regular))
                            .foregroundStyle(today ? .secondary : .tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(Int(day.amount.rounded()))% of the weekly limit")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(day.date.formatted(.dateTime.weekday(.wide))), \(Int(day.amount.rounded()))% of the weekly limit")
                }
            }
            }
            .padding(.top, 8)
        }
    }
}

/// The popover's Clawd, playing the same mood as the menu bar while the popover is open.
private struct ClawdView: View {
    let mood: Mood
    let sweating: Bool
    let animate: Bool

    var body: some View {
        let animation = MenuBarIcon.animation(mood)
        let frames = animation.frames.map { sweating ? MenuBarIcon.withSweat($0) : $0 }
        TimelineView(.periodic(from: .now, by: animation.frameDuration)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / animation.frameDuration)
            let index = animate ? (animation.repeats ? tick % frames.count : min(tick, frames.count - 1)) : 0
            Image(nsImage: MenuBarIcon.image(frames[index % frames.count]))
                .interpolation(.none)
                .opacity(mood == .asleep ? 0.45 : 1)
                .accessibilityHidden(true)
        }
    }
}

/// "today 4:00 PM" or "Mon 9:30 AM"; short enough to fit a meter column.
func dayAndTime(_ date: Date) -> String {
    let day = Calendar.current.isDateInToday(date) ? "today" : date.formatted(.dateTime.weekday(.abbreviated))
    return "\(day) \(date.formatted(date: .omitted, time: .shortened))"
}
