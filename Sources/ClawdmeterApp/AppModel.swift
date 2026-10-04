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

    var showCount: Bool { didSet { defaults.set(showCount, forKey: "showCount") } }
    var showLimit: Bool { didSet { defaults.set(showLimit, forKey: "showLimit") } }
    var animate: Bool { didSet { defaults.set(animate, forKey: "animate") } }
    var orangeIcon: Bool { didSet { defaults.set(orangeIcon, forKey: "orangeIcon") } }
    var notifyFinished: Bool { didSet { defaults.set(notifyFinished, forKey: "notifyFinished") } }
    var notifyWaiting: Bool { didSet { defaults.set(notifyWaiting, forKey: "notifyWaiting") } }
    var notifyLimits: Bool { didSet { defaults.set(notifyLimits, forKey: "notifyLimits") } }
    var notifySound: Bool { didSet { defaults.set(notifySound, forKey: "notifySound") } }

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
        guard let limits, !limits.isStale(), let used = limits.headline?.window.usedPercentage else { return false }
        return used >= 90
    }

    @ObservationIgnored var closePopover: (() -> Void)?

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }

    @ObservationIgnored let paths = ClaudePaths()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var directoryWatcher: DirectoryWatcher?
    @ObservationIgnored private var processWatcher: ProcessWatcher?
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var celebrationEnd: DispatchWorkItem?
    @ObservationIgnored private lazy var history = UsageHistory(file: paths.appDir.appending(path: "history.json"))

    init() {
        defaults.register(defaults: ["showCount": true, "showLimit": true, "animate": true, "orangeIcon": true,
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
        installStatus = InstallStatus(statusline: false, hooks: false, nativeSessions: false)
    }

    func start() {
        let installer = makeInstaller()
        installStatus = installer?.status() ?? installStatus
        if !defaults.bool(forKey: "didAutoInstall"), !(installStatus.statusline && installStatus.hooks) {
            defaults.set(true, forKey: "didAutoInstall")
            install()
        }
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
    }

    func reload() {
        let next = SessionMerger.merge(native: NativeSessionReader.read(paths), hooks: HookStateReader.read(paths),
                                       isAlive: isProcessAlive)
        let nextLimits = LimitsReader.read(paths)
        var events: [AppEvent] = []
        if loaded { events += EventDetector.sessionEvents(old: sessions, new: next) }
        var fired = Set(defaults.stringArray(forKey: "alertedLimits") ?? [])
        events += EventDetector.limitEvents(old: loaded ? limits : nil, new: nextLimits, fired: &fired)
        // Keys end in the window's reset time; once that passes they can never match again.
        let live = fired.filter { key in
            key.split(separator: "-").last.flatMap { Double($0) }.map { $0 == 0 || $0 > Date.now.timeIntervalSince1970 } ?? false
        }
        defaults.set(Array(live), forKey: "alertedLimits")
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
        events.forEach(handle)
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

    private func celebrate() {
        celebrationEnd?.cancel()
        celebrating = true
        let end = DispatchWorkItem { [weak self] in self?.celebrating = false }
        celebrationEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: end)
    }

    func install() {
        guard let installer = makeInstaller() else {
            installError = "Helper binary missing from the app bundle."
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
