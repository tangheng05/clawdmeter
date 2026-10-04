import AppKit
import ClawdmeterCore
import Foundation
import Observation

@MainActor
@Observable
final class Updater {
    enum Status: Equatable {
        case idle, checking, upToDate, installing
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
            if manual { status = .failed("Couldn't reach GitHub. Try again later.") }
            return
        }
        available = UpdateChecker.isNewer(release.version, than: currentVersion) ? release : nil
        if manual {
            status = available == nil ? .upToDate : .idle
            if available == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    if self?.status == .upToDate { self?.status = .idle }
                }
            }
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
            let newApp = try unpack(zip)
            try swapAndRelaunch(with: newApp)
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

    /// Replaces the running app once it has quit, keeping the old copy until the new one is in place.
    private func swapAndRelaunch(with newApp: URL) throws {
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app", Bundle.main.bundleIdentifier != nil else {
            throw UpdateError("Updates only work for the installed app.")
        }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError("Can't write to \(target.deletingLastPathComponent().path). Run the install command instead.")
        }
        let script = """
        while kill -0 "$PARENT" 2>/dev/null; do sleep 0.2; done
        mv "$TARGET" "$BACKUP" || exit 1
        if mv "$NEW" "$TARGET"; then rm -rf "$BACKUP"; else mv "$BACKUP" "$TARGET"; fi
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
            "BACKUP": newApp.deletingLastPathComponent().appending(path: "Clawdmeter-old.app").path,
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
