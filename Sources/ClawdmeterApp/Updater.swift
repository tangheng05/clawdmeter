import AppKit
import ClawdmeterCore
import Foundation
import Observation

@MainActor
@Observable
final class Updater {
    enum Status: Equatable {
        case idle, checking, upToDate, installing
        case checkFailed(String)
        case failed(String)
    }

    private(set) var available: ReleaseInfo?
    private(set) var status = Status.idle
    var automatic: Bool {
        didSet {
            UserDefaults.standard.set(automatic, forKey: "checkForUpdates")
            schedule()
        }
    }

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    let viaHomebrew = ["/opt/homebrew/Caskroom/clawdmeter", "/usr/local/Caskroom/clawdmeter"]
        .contains { FileManager.default.fileExists(atPath: $0) }

    @ObservationIgnored private var timer: Timer?

    init() {
        UserDefaults.standard.register(defaults: ["checkForUpdates": true])
        automatic = UserDefaults.standard.bool(forKey: "checkForUpdates")
    }

    func start() {
        schedule()
        guard automatic else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            Task { await self?.check() }
        }
    }

    /// One check a day, with loose timing so macOS can batch the wake-up.
    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard automatic else { return }
        let timer = Timer(timeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        timer.tolerance = 3600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func check(manual: Bool = false) async {
        guard status != .installing else { return }
        if manual { status = .checking }
        var request = URLRequest(url: UpdateChecker.latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = UpdateChecker.parseLatestRelease(data) else {
            if manual { showBriefly(.checkFailed("Couldn't reach GitHub. Check your connection and try again.")) }
            return
        }
        available = UpdateChecker.isNewer(release.version, than: currentVersion) ? release : nil
        if manual { available == nil ? showBriefly(.upToDate) : (status = .idle) }
    }

    /// Shows a passing message, then returns to idle unless something else happened meanwhile.
    private func showBriefly(_ message: Status) {
        status = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.status == message { self?.status = .idle }
        }
    }

    func openReleasePage() {
        if let url = available?.pageURL ?? URL(string: "https://github.com/tangheng05/clawdmeter/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }

    func install() async {
        guard let release = available else { return }
        guard let checksumURL = release.checksumURL else {
            status = .failed("This release can't be verified, so download it from GitHub instead.")
            return
        }
        status = .installing
        do {
            let (zip, _) = try await URLSession.shared.data(from: release.zipURL)
            let (checksum, _) = try await URLSession.shared.data(from: checksumURL)
            guard UpdateChecker.verifyChecksum(zip, checksumFile: String(decoding: checksum, as: UTF8.self)) else {
                throw UpdateError("The download didn't match its checksum, so it wasn't installed.")
            }
            let unpacked = try unpack(zip)
            defer { try? FileManager.default.removeItem(at: unpacked.deletingLastPathComponent()) }
            try swapAndRelaunch(with: unpacked)
        } catch let error as UpdateError {
            status = .failed(error.message)
        } catch {
            status = .failed("The download failed. Check your connection and try again.")
        }
    }

    private func unpack(_ zip: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "clawdmeter-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "Clawdmeter.zip")
        try zip.write(to: file)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", file.path, dir.path]
        try ditto.run()
        ditto.waitUntilExit()
        let app = dir.appending(path: "Clawdmeter.app")
        guard ditto.terminationStatus == 0,
              Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("The download wasn't a valid Clawdmeter app.")
        }
        return app
    }

    /// Replaces the running app once it has quit. The new copy is staged next to the app so both
    /// moves are same-volume renames, and the old copy is restored if anything fails.
    private func swapAndRelaunch(with unpacked: URL) throws {
        let target = Bundle.main.bundleURL
        let folder = target.deletingLastPathComponent()
        guard target.pathExtension == "app", Bundle.main.bundleIdentifier != nil else {
            throw UpdateError("Updates only work for the copy of Clawdmeter in Applications.")
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw UpdateError("Can't replace the app in \(folder.path). Download the new version from GitHub instead.")
        }
        let newApp = folder.appending(path: ".Clawdmeter-update.app")
        let backup = folder.appending(path: ".Clawdmeter-old.app")
        try? FileManager.default.removeItem(at: newApp)
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.moveItem(at: unpacked, to: newApp)
        let script = """
        while kill -0 "$PARENT" 2>/dev/null; do sleep 0.2; done
        if mv "$TARGET" "$BACKUP"; then
            if mv "$NEW" "$TARGET"; then rm -rf "$BACKUP"; else rm -rf "$TARGET"; mv "$BACKUP" "$TARGET"; fi
        fi
        rm -rf "$NEW"
        xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
        open "$TARGET"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = [
            "PARENT": String(ProcessInfo.processInfo.processIdentifier),
            "TARGET": target.path,
            "NEW": newApp.path,
            "BACKUP": backup.path,
            "PATH": "/usr/bin:/bin",
        ]
        try process.run()
        NSApp.terminate(nil)
    }
}

private struct UpdateError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
