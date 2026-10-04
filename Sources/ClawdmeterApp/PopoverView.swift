import ClawdmeterCore
import SwiftUI

struct PopoverView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            LimitsSection(limits: model.limits)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            Divider()
            SessionsSection(sessions: model.sessions)
            if !(model.installStatus.statusline && model.installStatus.hooks) || model.installError != nil {
                Divider()
                SetupBanner(model: model)
            }
            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: MenuBarIcon.image(frame: 0, orange: true))
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
            Menu {
                Toggle("Show session count", isOn: $model.showCount)
                Toggle("Show usage in menu bar", isOn: $model.showLimit)
                Toggle("Animate while working", isOn: $model.animate)
                Toggle("Orange icon", isOn: $model.orangeIcon)
                Divider()
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Divider()
                if model.installStatus.statusline || model.installStatus.hooks {
                    Button("Reinstall Claude Code integration") { model.install() }
                    Button("Remove Claude Code integration") { model.uninstall() }
                } else {
                    Button("Install Claude Code integration") { model.install() }
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
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

    var body: some View {
        if let limits {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 20) {
                    Meter(title: "5-hour", window: limits.fiveHour, resetStyle: .countdown)
                    Meter(title: "Weekly", window: limits.sevenDay, resetStyle: .clock)
                }
                if limits.isStale() {
                    Text("Last updated \(limits.updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .opacity(limits.isStale() ? 0.6 : 1)
        } else {
            Text("Usage limits show up after your next Claude Code message.")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(window.map { "\(Int($0.usedPercentage.rounded(.down)))%" } ?? "–")
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                .foregroundStyle(usageColor(window?.usedPercentage ?? 0))
                .contentTransition(.numericText())
            bar
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(resetText(now: context.date))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
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

    private func resetText(now: Date) -> String {
        guard let reset = window?.resetsAt, reset > now else { return " " }
        switch resetStyle {
        case .countdown:
            let minutes = Int(reset.timeIntervalSince(now) / 60)
            return minutes >= 60 ? "resets in \(minutes / 60)h \(minutes % 60)m" : "resets in \(max(minutes, 1))m"
        case .clock:
            let day = Calendar.current.isDateInToday(reset) ? "today"
                : Calendar.current.isDateInTomorrow(reset) ? "tomorrow"
                : reset.formatted(.dateTime.weekday(.abbreviated))
            return "resets \(day) \(reset.formatted(date: .omitted, time: .shortened))"
        }
    }
}

private struct SessionsSection: View {
    let sessions: [Session]

    var body: some View {
        if sessions.isEmpty {
            Text("Start `claude` in a terminal and it shows up here.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        } else {
            let list = VStack(spacing: 0) {
                ForEach(sessions) { SessionRow(session: $0) }
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

    var body: some View {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .help(session.cwd)
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
        case .waiting: session.waitingFor.map { "Needs you: \($0)" } ?? "Needs you"
        case .working: session.tool.map { "Running \($0)" } ?? "Thinking"
        case .idle:
            Date.now.timeIntervalSince(session.since) >= 60
                ? "Idle for \(elapsed(from: session.since, to: .now, coarse: true))" : "Idle"
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
