import AppKit
import ClawdmeterCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var notificationsBlocked = false
    @State private var loginNeedsApproval = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Toggle("Show usage in the menu bar", isOn: $model.showLimit)
                Toggle("Show session count in the menu bar", isOn: $model.showCount)
                Toggle("Animate Clawd", isOn: $model.animate)
                Picker("Clawd's color", selection: $model.orangeIcon) {
                    Text("Orange").tag(true)
                    Text("Match the menu bar").tag(false)
                }
                if loginNeedsApproval {
                    NoticeRow(title: "Login item needs your approval",
                              detail: "Allow Clawdmeter in Login Items so it starts with your Mac.",
                              action: "Open Settings") { SMAppService.openSystemSettingsLoginItems() }
                }
            } header: {
                Text("General")
            }

            Section {
                Toggle("A task finishes", isOn: $model.notifyFinished)
                Toggle("A session needs me", isOn: $model.notifyWaiting)
                Toggle("A limit gets close or resets", isOn: $model.notifyLimits)
                Toggle("Play a sound", isOn: $model.notifySound)
                if notificationsBlocked {
                    NoticeRow(title: "Notifications are off",
                              detail: "Turn them on for Clawdmeter in System Settings.",
                              action: "Open Settings", perform: openNotificationSettings)
                }
            } header: {
                Text("Notify me when")
            }

            Section {
                LabeledContent("Open Clawdmeter") {
                    ShortcutRecorder(model: model)
                }
            } header: {
                Text("Keyboard shortcut")
            } footer: {
                if model.shortcutTaken {
                    Text("Another app already uses this shortcut. Pick a different one.").foregroundStyle(.red)
                }
            }

            Section {
                Toggle("Check for updates automatically", isOn: Bindable(model.updater).automatic)
                LabeledContent("Version \(model.updater.currentVersion)") {
                    Button("Check now") { Task { await model.updater.check(manual: true) } }
                        .disabled(model.updater.status == .checking || model.updater.status == .installing)
                }
            } header: {
                Text("Updates")
            } footer: {
                updateStatus
            }

            Section {
                LabeledContent("Status") {
                    let connected = model.installStatus.statusline && model.installStatus.hooks
                    HStack(spacing: 10) {
                        Text(connected ? "Connected" : "Not connected").foregroundStyle(.secondary)
                        if connected {
                            Button("Disconnect") { model.uninstall() }
                        } else {
                            Button("Connect") { model.install() }
                        }
                    }
                }
            } header: {
                Text("Claude Code")
            } footer: {
                if let error = model.installError {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("Clawdmeter adds a status line and a few hooks to Claude Code's settings, and keeps a backup.")
                }
            }
        }
        .formStyle(.grouped)
        .task { await refreshSystemState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshSystemState() }
        }
        // Fits a 13-inch screen; the form scrolls if it needs more room.
        .frame(width: 440, height: 620)
    }

    private func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Re-read when Settings appears or you come back from System Settings.
    private func refreshSystemState() async {
        notificationsBlocked = await model.notifier.isBlocked()
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    @ViewBuilder private var updateStatus: some View {
        switch model.updater.status {
        case .checking: Text("Checking…")
        case .upToDate: Text("You're on the latest version.")
        case .installing: Text("Updating…")
        case .failed(let message): Text(message).foregroundStyle(.red)
        case .checkFailed(let message): Text(message)
        case .idle:
            if let version = model.updater.available?.version {
                Text(model.updater.viaHomebrew
                     ? "Version \(version) is available. Run brew upgrade clawdmeter in Terminal."
                     : "Version \(version) is available. Click Clawd in the menu bar, then Update.")
            }
        }
    }
}

/// Click, then press a key combination; Esc cancels.
private struct ShortcutRecorder: View {
    @Bindable var model: AppModel
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                Text(label)
                    .frame(minWidth: 96)
                    .foregroundStyle(model.recordingShortcut ? .secondary : .primary)
            }
            if model.shortcut != nil, !model.recordingShortcut {
                Button {
                    model.shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Turn off the shortcut")
                .accessibilityLabel("Turn off the shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if model.recordingShortcut { return hint ?? "Press keys…" }
        return model.shortcut?.display ?? "Record shortcut"
    }

    private func toggleRecording() {
        model.recordingShortcut ? stop() : start()
    }

    private func start() {
        model.recordingShortcut = true
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { record(event) }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        model.recordingShortcut = false
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == 53 { return stop() }
        let flags = event.modifierFlags
        let combo = KeyCombo(keyCode: UInt32(event.keyCode), key: keyName(event),
                             command: flags.contains(.command), option: flags.contains(.option),
                             control: flags.contains(.control), shift: flags.contains(.shift))
        guard combo.isValid else {
            hint = "Add ⌘, ⌥ or ⌃"
            return
        }
        model.shortcut = combo
        stop()
    }

    private func keyName(_ event: NSEvent) -> String {
        switch event.keyCode {
        case 49: return "Space"
        case 36: return "↩"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let key = event.charactersIgnoringModifiers ?? ""
            return key.unicodeScalars.allSatisfy { $0.properties.isAlphabetic || $0.properties.numericType != nil
                || CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) } ? key : ""
        }
    }
}

/// A row that explains something blocking a feature, with the one action that fixes it.
private struct NoticeRow: View {
    let title: String
    let detail: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(action, action: perform)
        }
    }
}
