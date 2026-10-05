import AppKit
import ClawdmeterCore
import SwiftUI
import UserNotifications

/// Shown once on first launch. Clawd waves while something still needs you and hops once
/// everything is set, which also teaches what its moods mean in the menu bar.
struct WelcomeView: View {
    @Bindable var model: AppModel
    let finish: () -> Void
    @State private var notifications = UNAuthorizationStatus.notDetermined

    private var connected: Bool { model.installStatus.statusline && model.installStatus.hooks }
    private var notificationsDecided: Bool { notifications != .notDetermined }
    private var ready: Bool { connected && notificationsDecided && model.launchAtLogin }

    var body: some View {
        VStack(spacing: 0) {
            BigClawd(mood: ready ? .done : .waiting)
                .padding(.bottom, 22)

            Text("Clawd now lives in your menu bar")
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.3)
            Text("It shows what Claude Code is doing and how much of your limits are left. Find it at the top right of your screen.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            setup
                .padding(.top, 26)

            if let shortcut = model.shortcut {
                HStack(spacing: 8) {
                    Text("Open it from anywhere with").foregroundStyle(.secondary)
                    KeyCaps(keys: shortcut.display.map(String.init))
                }
                .font(.system(size: 12))
                .padding(.top, 18)
                .accessibilityElement(children: .combine)
            }

            HStack {
                Spacer()
                Button("Open Clawdmeter", action: finish)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 24)
        }
        .padding(.horizontal, 36)
        .padding(.top, 44)
        .padding(.bottom, 28)
        .frame(width: 500)
        .task { notifications = await model.notifier.authorizationStatus() }
    }

    private var setup: some View {
        VStack(spacing: 0) {
            SetupRow(done: connected,
                     title: connected ? "Connected to Claude Code" : "Not connected to Claude Code",
                     detail: connected ? "Your sessions show up as soon as Claude does something."
                                       : model.installError ?? "Clawdmeter needs a few hooks in Claude Code's settings.") {
                if !connected { Button("Connect") { model.install() } }
            }
            Divider().padding(.leading, 44)
            SetupRow(done: notifications == .authorized || notifications == .provisional, title: "Notifications",
                     detail: "Know when a task finishes or a session needs you.") {
                switch notifications {
                case .notDetermined:
                    Button("Allow") { Task { notifications = await model.notifier.requestPermissionNow() } }
                case .denied:
                    Button("Open Settings") {
                        let id = Bundle.main.bundleIdentifier ?? ""
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                default:
                    Text("On").foregroundStyle(.secondary)
                }
            }
            Divider().padding(.leading, 44)
            SetupRow(done: model.launchAtLogin, title: "Open at login",
                     detail: "Clawd is back after you restart your Mac.") {
                Toggle("Open at login", isOn: $model.launchAtLogin)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { notifications = await model.notifier.authorizationStatus() }
        }
    }
}

private struct SetupRow<Trailing: View>: View {
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(done ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 20)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityLabel(done ? "Done" : "Not set up")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }
}

/// The shortcut drawn as keys, one cap per symbol.
private struct KeyCaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, key.count > 1 ? 6 : 0)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                    .shadow(color: .black.opacity(0.18), radius: 0, y: 1)
            }
        }
    }
}

/// Clawd at poster size, drawn from the same pixel frames as the menu bar icon.
private struct BigClawd: View {
    let mood: Mood
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let unit: CGFloat = 3

    var body: some View {
        VStack(spacing: unit) {
            AnimatedClawd(mood: mood, animate: !reduceMotion)
                .frame(width: unit * MenuBarIcon.pointSize.width, height: unit * MenuBarIcon.pointSize.height)
            // A pixel shadow grounds Clawd so the hop reads as a jump.
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: unit * 20, height: unit)
                // Under Clawd's body, which sits left of center.
                .offset(x: -unit * 4.5)
        }
        .accessibilityHidden(true)
    }
}
