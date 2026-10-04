import ClawdmeterCore
import SwiftUI

struct PopoverView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            LimitsSection(limits: model.limits)
                .padding(14)
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
        HStack(spacing: 8) {
            Image(nsImage: MenuBarIcon.image(frame: 0, orange: true))
            Text("clawdmeter").font(.headline)
            Spacer()
            Text(summary).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var summary: String {
        let s = model.sessions
        if s.isEmpty { return "No sessions" }
        let working = s.filter { $0.state == .working }.count
        let waiting = s.filter { $0.state == .waiting }.count
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if working > 0 { parts.append("\(working) working") }
        if parts.isEmpty { parts.append(s.count == 1 ? "1 idle" : "\(s.count) idle") }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack {
            Menu {
                Toggle("Show session count", isOn: $model.showCount)
                Toggle("Show 5-hour usage", isOn: $model.showLimit)
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
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct LimitsSection: View {
    let limits: RateLimits?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let limits, limits.fiveHour != nil || limits.sevenDay != nil {
                let stale = limits.isStale()
                LimitBar(title: "5-hour", window: limits.fiveHour)
                LimitBar(title: "Weekly", window: limits.sevenDay)
                if stale {
                    Text("As of \(limits.updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            } else {
                Text("Usage limits appear after your next Claude Code message.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(limits?.isStale() == true ? 0.55 : 1)
    }
}

private struct LimitBar: View {
    let title: String
    let window: LimitWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                if let window {
                    if let reset = window.resetsAt, reset > .now {
                        Text("resets \(reset, format: .relative(presentation: .named))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(Int(window.usedPercentage.rounded(.down)))%")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color)
                        .frame(width: geo.size.width * min(max((window?.usedPercentage ?? 0) / 100, 0), 1))
                }
            }
            .frame(height: 6)
        }
    }

    private var color: Color {
        let used = window?.usedPercentage ?? 0
        if used >= 90 { return .red }
        if used >= 70 { return .orange }
        return Color(nsColor: MenuBarIcon.claudeOrange)
    }
}

private struct SessionsSection: View {
    let sessions: [Session]

    var body: some View {
        if sessions.isEmpty {
            Text("No Claude Code sessions running")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 18)
        } else {
            let list = VStack(spacing: 2) {
                ForEach(sessions) { SessionRow(session: $0) }
            }
            .padding(6)
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
        HStack(spacing: 10) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName).font(.callout.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            TimelineView(.periodic(from: session.since, by: 1)) { context in
                Text(elapsed(from: session.since, to: context.date))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .help(session.cwd)
    }

    private var dotColor: Color {
        switch session.state {
        case .waiting: .yellow
        case .working: Color(nsColor: MenuBarIcon.claudeOrange)
        case .idle: .secondary.opacity(0.5)
        }
    }

    private var detail: String {
        switch session.state {
        case .waiting: "Needs you" + (session.waitingFor.map { " · \($0)" } ?? "")
        case .working: session.tool.map { "Running \($0)" } ?? "Thinking"
        case .idle: "Idle"
        }
    }
}

private struct SetupBanner: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.installError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else {
                Text("Install the Claude Code integration to see tool activity and usage limits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Install") { model.install() }.controlSize(.small)
        }
        .padding(14)
    }
}

func elapsed(from start: Date, to end: Date) -> String {
    let seconds = max(0, Int(end.timeIntervalSince(start)))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
    return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
}
