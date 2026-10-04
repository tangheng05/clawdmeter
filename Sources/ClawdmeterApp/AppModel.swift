import ClawdmeterCore
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppModel {
    private(set) var sessions: [Session] = []
    private(set) var limits: RateLimits?
    private(set) var aggregate = Aggregate(sessions: [])
    private(set) var installStatus: InstallStatus
    private(set) var installError: String?

    var showCount: Bool { didSet { defaults.set(showCount, forKey: "showCount") } }
    var showLimit: Bool { didSet { defaults.set(showLimit, forKey: "showLimit") } }
    var animate: Bool { didSet { defaults.set(animate, forKey: "animate") } }
    var orangeIcon: Bool { didSet { defaults.set(orangeIcon, forKey: "orangeIcon") } }

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

    init() {
        defaults.register(defaults: ["showCount": true, "showLimit": true, "animate": true, "orangeIcon": true])
        showCount = defaults.bool(forKey: "showCount")
        showLimit = defaults.bool(forKey: "showLimit")
        animate = defaults.bool(forKey: "animate")
        orangeIcon = defaults.bool(forKey: "orangeIcon")
        installStatus = InstallStatus(statusline: false, hooks: false, nativeSessions: false)
    }

    func start() {
        let installer = makeInstaller()
        installStatus = installer?.status() ?? installStatus
        if !defaults.bool(forKey: "didAutoInstall"), !(installStatus.statusline && installStatus.hooks) {
            defaults.set(true, forKey: "didAutoInstall")
            install()
        }
        processWatcher = ProcessWatcher { [weak self] in self?.reload() }
        directoryWatcher = DirectoryWatcher(directories: [paths.sessionsDir, paths.appDir]) { [weak self] in
            self?.reload()
        }
        reload()
    }

    func reload() {
        let next = SessionMerger.merge(native: NativeSessionReader.read(paths), hooks: HookStateReader.read(paths),
                                       isAlive: isProcessAlive)
        if next != sessions {
            sessions = next
            aggregate = Aggregate(sessions: next)
        }
        let nextLimits = LimitsReader.read(paths)
        if nextLimits != limits { limits = nextLimits }
        processWatcher?.watch(Set(next.map(\.pid)))
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
