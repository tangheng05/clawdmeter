import ClawdmeterCore
import Foundation
import Observation
import AppKit
import ServiceManagement

@MainActor
@Observable
final class AppModel {
    private(set) var sessions: [Session] = []
    private(set) var limits: RateLimits?
    private(set) var aggregate = Aggregate(sessions: [])
    private(set) var installStatus: InstallStatus
    private(set) var installError: String?
    private(set) var dailyUsage: [UsageHistory.Day] = []
    private(set) var celebrating = false
    /// Bumped when a limit window resets, so time-based views refresh.
    private var resetTick = 0

    /// Limits as they stand now: windows past their reset read as 0%.
    var currentLimits: RateLimits? {
        _ = resetTick
        return limits?.current()
    }

    var showCount: Bool { didSet { defaults.set(showCount, forKey: "showCount") } }
    var showLimit: Bool { didSet { defaults.set(showLimit, forKey: "showLimit") } }
    var animate: Bool { didSet { defaults.set(animate, forKey: "animate") } }
    var orangeIcon: Bool { didSet { defaults.set(orangeIcon, forKey: "orangeIcon") } }
    var notifyFinished: Bool { didSet { defaults.set(notifyFinished, forKey: "notifyFinished") } }
    var notifyWaiting: Bool { didSet { defaults.set(notifyWaiting, forKey: "notifyWaiting") } }
    var notifyLimits: Bool { didSet { defaults.set(notifyLimits, forKey: "notifyLimits") } }
    var notifySound: Bool { didSet { defaults.set(notifySound, forKey: "notifySound") } }
    /// nil means the shortcut is turned off.
    var shortcut: KeyCombo? {
        didSet {
            let stored = shortcut.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
            defaults.set(stored ?? "off", forKey: "keyCombo")
        }
    }
    var shortcutTaken = false
    var recordingShortcut = false

    var mood: Mood {
        if celebrating { return .done }
        if sessions.isEmpty { return .asleep }
        switch aggregate.state {
        case .waiting: return .waiting
        case .working: return .working
        case .idle: return .idle
        }
    }

    var sweating: Bool {
        guard let limits = currentLimits, !limits.isStale(), let used = limits.headline?.window.usedPercentage
        else { return false }
        return used >= 90
    }

    @ObservationIgnored var closePopover: (() -> Void)?
    @ObservationIgnored var openSettings: (() -> Void)?
    let updater = Updater()

    /// Stored so SwiftUI sees changes; the system setting is the source of truth.
    var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            try? launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    @ObservationIgnored let paths = ClaudePaths()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var directoryWatcher: DirectoryWatcher?
    @ObservationIgnored private var processWatcher: ProcessWatcher?
    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var memory = SessionMemory()
    @ObservationIgnored private let alertLog = AlertLog()
    @ObservationIgnored private var celebrationEnd: DispatchWorkItem?
    @ObservationIgnored private var resetTimer: Timer?
    @ObservationIgnored private lazy var history = UsageHistory(file: paths.appDir.appending(path: "history.json"))

    init() {
        defaults.register(defaults: ["showCount": true, "showLimit": true, "orangeIcon": true,
                                     "animate": !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                     "notifyFinished": true, "notifyWaiting": true, "notifyLimits": true,
                                     "notifySound": true])
        showCount = defaults.bool(forKey: "showCount")
        showLimit = defaults.bool(forKey: "showLimit")
        animate = defaults.bool(forKey: "animate")
        orangeIcon = defaults.bool(forKey: "orangeIcon")
        notifyFinished = defaults.bool(forKey: "notifyFinished")
        notifyWaiting = defaults.bool(forKey: "notifyWaiting")
        notifyLimits = defaults.bool(forKey: "notifyLimits")
        notifySound = defaults.bool(forKey: "notifySound")
        shortcut = Self.loadShortcut(defaults)
        installStatus = InstallStatus(statusline: false, hooks: false, nativeSessions: false)
    }

    func start() {
        let installer = makeInstaller()
        installStatus = installer?.status() ?? installStatus
        if !defaults.bool(forKey: "didAutoInstall"), !(installStatus.statusline && installStatus.hooks) {
            defaults.set(true, forKey: "didAutoInstall")
            install()
        }
        installer?.refreshHelperIfNeeded()
        // A menu bar app is only useful if it's there after a restart.
        if !defaults.bool(forKey: "didSetLaunchAtLogin") {
            defaults.set(true, forKey: "didSetLaunchAtLogin")
            launchAtLogin = true
        }
        notifier.requestPermission()
        notifier.onOpen = { [weak self] id in
            guard let session = self?.sessions.first(where: { $0.id == id }) else { return }
            Focuser.focus(session)
        }
        dailyUsage = UsageHistory.dailyUsage(history.load(), days: 7)
        processWatcher = ProcessWatcher { [weak self] in self?.reload() }
        directoryWatcher = DirectoryWatcher(directories: [paths.sessionsDir, paths.appDir]) { [weak self] in
            self?.reload()
        }
        reload()
        updater.start()
    }

    func reload() {
        let next = SessionMerger.merge(native: NativeSessionReader.read(paths), hooks: HookStateReader.read(paths),
                                       isAlive: isSessionProcess)
        let nextLimits = LimitsReader.read(paths)
        var events: [AppEvent] = []
        let sessionEvents = memory.advance(to: next, isAlive: isProcessAlive)
        if loaded { events += sessionEvents }
        var fired = alertLog.load()
        events += EventDetector.limitEvents(new: nextLimits, fired: &fired)
        alertLog.save(fired)
        loaded = true

        if next != sessions {
            sessions = next
            aggregate = Aggregate(sessions: next)
        }
        if nextLimits != limits {
            limits = nextLimits
            if let nextLimits {
                history.record(nextLimits)
                dailyUsage = UsageHistory.dailyUsage(history.load(), days: 7)
            }
        }
        processWatcher?.watch(Set(next.map(\.pid)))
        scheduleResetRefresh()
        events.forEach(handle)
    }

    private static func loadShortcut(_ defaults: UserDefaults) -> KeyCombo? {
        if let stored = defaults.string(forKey: "keyCombo") {
            return stored == "off" ? nil : (try? JSONDecoder().decode(KeyCombo.self, from: Data(stored.utf8))) ?? .default
        }
        // Earlier versions offered a fixed choice.
        switch defaults.string(forKey: "shortcut") {
        case "off": return nil
        case "optionCommandC":
            return KeyCombo(keyCode: 8, key: "c", command: true, option: true, control: false, shift: false)
        case "controlOptionCommandC":
            return KeyCombo(keyCode: 8, key: "c", command: true, option: true, control: true, shift: false)
        default: return .default
        }
    }

    func focus(_ session: Session) {
        closePopover?()
        Focuser.focus(session)
    }

    private func handle(_ event: AppEvent) {
        switch event {
        case .finished(let id, _, _):
            celebrate()
            if notifyFinished { notifyAboutSession(event, id: id) }
        case .needsYou(let id, _):
            if notifyWaiting { notifyAboutSession(event, id: id) }
        case .limitCrossed, .limitReset:
            if notifyLimits { notifier.post(event, sound: notifySound) }
        }
    }

    /// Skips the notification when you're already looking at that session's app.
    private func notifyAboutSession(_ event: AppEvent, id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let host = Focuser.hostPID(for: session), host == front { return }
        notifier.post(event, sessionId: id, sound: notifySound)
    }

    /// One-shot timer at the next reset, so the meters drop and the reset notice arrives on time.
    private func scheduleResetRefresh() {
        resetTimer?.invalidate()
        guard let reset = limits?.nextReset() else { return }
        let timer = Timer(fire: reset.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resetTick += 1
                self?.reload()
            }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        resetTimer = timer
    }

    private func celebrate() {
        celebrationEnd?.cancel()
        celebrating = true
        let end = DispatchWorkItem { [weak self] in self?.celebrating = false }
        celebrationEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: end)
    }

    func install() {
        guard let installer = makeInstaller() else {
            installError = "Clawdmeter's files are incomplete. Reinstall it from github.com/tangheng05/clawdmeter."
            return
        }
        do {
            try installer.install()
            installError = nil
        } catch {
            installError = error.localizedDescription
        }
        installStatus = installer.status()
    }

    func uninstall() {
        guard let installer = makeInstaller() else { return }
        do {
            try installer.uninstall()
            installError = nil
        } catch {
            installError = error.localizedDescription
        }
        installStatus = installer.status()
    }

    private func makeInstaller() -> Installer? {
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/clawdmeter")
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "clawdmeter")
        let fm = FileManager.default
        guard let source = [bundled, sibling].compactMap({ $0 }).first(where: { fm.isExecutableFile(atPath: $0.path) })
        else { return nil }
        return Installer(paths: paths, helperSource: source)
    }
}
