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
    private(set) var spend: SpendSummary?
    private(set) var plan: String?
    private(set) var accountEmail: String?
    private(set) var accountOrganization: String?
    /// The signed-in account shown under the headline, after a click on the plan badge.
    var accountExpanded = false
    /// True while the screen is being shared and usage should stay out of the menu bar.
    private(set) var screenShared = false
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
    /// Limits read as what's left instead of what's used.
    var showRemaining: Bool { didSet { defaults.set(showRemaining, forKey: "showRemaining") } }
    var hideWhenSharing: Bool {
        didSet {
            defaults.set(hideWhenSharing, forKey: "hideWhenSharing")
            watchScreenSharing()
        }
    }
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
        case .working: return sessions.contains(where: \.compacting) ? .compacting : .working
        case .idle: return .idle
        }
    }

    var sweating: Bool {
        guard let used = currentLimits?.headline?.window.usedPercentage else { return false }
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
    @ObservationIgnored private lazy var transcripts = TranscriptCache(paths: paths)
    @ObservationIgnored private var celebrationEnd: DispatchWorkItem?
    @ObservationIgnored private var resetTimer: Timer?
    @ObservationIgnored private lazy var history = UsageHistory(file: historyFile(for: nil))
    @ObservationIgnored private var account: String?
    @ObservationIgnored private var cachedLimits: RateLimits?
    @ObservationIgnored private var accountFileModified: Date?
    @ObservationIgnored private lazy var spendIndex = SpendIndex(paths: paths)
    @ObservationIgnored private var spendRefreshing = false

    init() {
        defaults.register(defaults: ["showCount": true, "showLimit": true, "orangeIcon": true,
                                     "animate": !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                     "notifyFinished": true, "notifyWaiting": true, "notifyLimits": true,
                                     "notifySound": true])
        showCount = defaults.bool(forKey: "showCount")
        showLimit = defaults.bool(forKey: "showLimit")
        animate = defaults.bool(forKey: "animate")
        orangeIcon = defaults.bool(forKey: "orangeIcon")
        showRemaining = defaults.bool(forKey: "showRemaining")
        hideWhenSharing = defaults.bool(forKey: "hideWhenSharing")
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
        // Newer versions listen to more hook events; add them for people already connected.
        if installStatus.statusline, !installStatus.hooks { install() }
        // A menu bar app is only useful if it's there after a restart.
        if !defaults.bool(forKey: "didSetLaunchAtLogin") {
            defaults.set(true, forKey: "didSetLaunchAtLogin")
            launchAtLogin = true
        }
        // New users are asked from the welcome screen instead, with context.
        if defaults.bool(forKey: "didShowWelcome") { notifier.requestPermission() }
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
        watchScreenSharing()
        updater.start()
        // The first read of the logs is the only slow one, so do it before the popover is opened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.refreshSpend() }
    }

    func reload() {
        let windows = ContextWindows.load(paths)
        let next = SessionMerger.merge(native: NativeSessionReader.read(paths), hooks: HookStateReader.read(paths),
                                       context: ContextReader.read(paths),
                                       transcript: { [transcripts] in transcripts.context(forSession: $0, windows: windows) },
                                       isAlive: isSessionProcess)
        refreshAccount()
        let nextLimits = RateLimits.best(LimitsReader.read(paths), cached: cachedLimits, account: account)
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

    private func watchScreenSharing() {
        if hideWhenSharing, ScreenShare.isAvailable {
            ScreenShare.observe { [weak self] in self?.recheckScreenSharing() }
        }
        recheckScreenSharing()
    }

    private func recheckScreenSharing() {
        let shared = hideWhenSharing && ScreenShare.isActive
        if screenShared != shared { screenShared = shared }
    }

    /// Reads only the log lines added since last time, off the main thread. Runs when the popover
    /// opens rather than on every log write, so idle Clawdmeter does no work.
    func refreshSpend() {
        guard !spendRefreshing else { return }
        spendRefreshing = true
        let index = spendIndex
        Task { [weak self] in
            let summary = await Task.detached(priority: .utility) { index.refresh() }.value
            guard let self else { return }
            spendRefreshing = false
            if spend != summary { spend = summary }
        }
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

    /// Re-reads the signed-in account only when Claude Code's account file changes.
    private func refreshAccount() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: paths.accountFile.path))?[.modificationDate] as? Date
        guard modified != accountFileModified || modified == nil else { return }
        accountFileModified = modified
        let snapshot = Account.read(paths)
        cachedLimits = snapshot.cachedLimits
        if plan != snapshot.plan { plan = snapshot.plan }
        if accountEmail != snapshot.email { accountEmail = snapshot.email }
        if accountOrganization != snapshot.organization { accountOrganization = snapshot.organization }
        let next = snapshot.account
        guard next != account else { return }
        account = next
        let file = historyFile(for: next)
        // History from before accounts were tracked belongs to whoever is signed in now.
        let legacy = historyFile(for: nil)
        if next != nil, !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.moveItem(at: legacy, to: file)
        }
        history = UsageHistory(file: file)
        dailyUsage = UsageHistory.dailyUsage(history.load(), days: 7)
    }

    /// One usage history per account, so switching accounts never mixes their charts.
    private func historyFile(for account: String?) -> URL {
        let name = account.map { "history-\($0.prefix(8)).json" } ?? "history.json"
        return paths.appDir.appending(path: name)
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
        case .limitReset:
            celebrate(for: 2.4)
            if notifyLimits { notifier.post(event, sound: notifySound) }
        case .limitCrossed:
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

    private func celebrate(for duration: TimeInterval = 1.2) {
        celebrationEnd?.cancel()
        celebrating = true
        let end = DispatchWorkItem { [weak self] in self?.celebrating = false }
        celebrationEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: end)
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
