import Foundation
import Testing
@testable import ClawdmeterCore

@Suite struct AuditTests {
    let now = Date(timeIntervalSince1970: 10_000)

    func session(_ id: String, _ state: SessionState, since: TimeInterval, pid: Int32 = 1) -> Session {
        Session(id: id, pid: pid, cwd: "/w/\(id)", name: nil, state: state, since: Date(timeIntervalSince1970: since))
    }

    @Test func sessionMissingForOneReadDoesNotRenotify() {
        var memory = SessionMemory()
        _ = memory.advance(to: [session("a", .waiting, since: 9_000)], isAlive: { _ in true }, now: now)
        #expect(memory.advance(to: [], isAlive: { _ in true }, now: now).isEmpty)
        #expect(memory.advance(to: [session("a", .waiting, since: 9_000)], isAlive: { _ in true }, now: now).isEmpty)
    }

    @Test func finishAcrossAMissedReadIsStillDetected() {
        var memory = SessionMemory()
        _ = memory.advance(to: [session("a", .working, since: 9_000)], isAlive: { _ in true }, now: now)
        _ = memory.advance(to: [], isAlive: { _ in true }, now: now)
        let events = memory.advance(to: [session("a", .idle, since: 10_000)], isAlive: { _ in true }, now: now)
        #expect(events == [.finished(sessionId: "a@1", name: "a", duration: 1_000)])
    }

    @Test func endedSessionsAreForgotten() {
        var memory = SessionMemory()
        _ = memory.advance(to: [session("a", .waiting, since: 9_000, pid: 7)], isAlive: { _ in true }, now: now)
        _ = memory.advance(to: [], isAlive: { _ in false }, now: now)
        #expect(memory.advance(to: [session("a", .waiting, since: 9_000, pid: 7)], isAlive: { _ in true }, now: now)
            == [.needsYou(sessionId: "a@7", name: "a")])
    }

    @Test func driftingResetTimeDoesNotRepeatAlerts() {
        var fired = Set<String>()
        func limits(reset: TimeInterval) -> RateLimits {
            RateLimits(fiveHour: LimitWindow(usedPercentage: 85, resetsAt: Date(timeIntervalSince1970: reset)),
                       sevenDay: nil, updatedAt: now)
        }
        #expect(EventDetector.limitEvents(new: limits(reset: 36_000), now: now, fired: &fired).count == 1)
        #expect(EventDetector.limitEvents(new: limits(reset: 36_001), now: now, fired: &fired).isEmpty)
    }

    @Test func statuslineSkipsUnchangedWritesForAMinute() throws {
        let dir = try TempDir()
        let payload = Data(#"{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1}}}"#.utf8)
        _ = StatuslineHandler.handle(input: payload, paths: dir.paths, now: now, runPrevious: { _, _ in nil })
        _ = StatuslineHandler.handle(input: payload, paths: dir.paths, now: now.addingTimeInterval(30),
                                     runPrevious: { _, _ in nil })
        #expect(LimitsReader.read(dir.paths)?.updatedAt == now)
        _ = StatuslineHandler.handle(input: payload, paths: dir.paths, now: now.addingTimeInterval(61),
                                     runPrevious: { _, _ in nil })
        #expect(LimitsReader.read(dir.paths)?.updatedAt == now.addingTimeInterval(61))
        let changed = Data(#"{"rate_limits":{"five_hour":{"used_percentage":11,"resets_at":1}}}"#.utf8)
        _ = StatuslineHandler.handle(input: changed, paths: dir.paths, now: now.addingTimeInterval(62),
                                     runPrevious: { _, _ in nil })
        #expect(LimitsReader.read(dir.paths)?.fiveHour?.usedPercentage == 11)
    }

    @Test func helperIsRefreshedWhenTheAppUpdates() throws {
        let dir = try TempDir()
        try dir.write("v1", to: "helper-src")
        let installer = Installer(paths: dir.paths, helperSource: dir.url.appending(path: "helper-src"))
        try installer.install()
        try dir.write("v2", to: "helper-src")
        #expect(installer.refreshHelperIfNeeded())
        #expect(try String(contentsOf: dir.paths.helperPath, encoding: .utf8) == "v2")
        #expect(!installer.refreshHelperIfNeeded())
    }

    @Test func helperIsNotInstalledByRefreshAlone() throws {
        let dir = try TempDir()
        try dir.write("v1", to: "helper-src")
        let installer = Installer(paths: dir.paths, helperSource: dir.url.appending(path: "helper-src"))
        #expect(!installer.refreshHelperIfNeeded())
        #expect(!FileManager.default.fileExists(atPath: dir.paths.helperPath.path))
    }
}

@Suite struct AlertLogTests {
    @Test func roundTripsThroughUserDefaults() throws {
        let suite = "clawdmeter-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = AlertLog(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_000_000)
        log.save(["5-hour-80-300", "Weekly-95-5"], now: now)
        #expect(log.load() == ["5-hour-80-300"])
    }
}

@Suite struct AlertKeyTests {
    @Test func legacyEpochKeysExpire() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!EventDetector.isLive(alertKey: "Weekly-80-1791190800", now: now))
        #expect(EventDetector.isLive(alertKey: "Weekly-80-1801190800", now: now))
        #expect(EventDetector.isLive(alertKey: "Weekly-80-500300", now: now))
    }
}

@Suite struct ReliabilityTests {
    @Test func sameSessionInTwoProcessesStaysSeparate() {
        let native = [
            NativeSessionRecord(pid: 1, sessionId: "s", cwd: "/a", name: nil, state: .waiting, waitingFor: "x",
                                statusChangedAt: Date(timeIntervalSince1970: 5)),
            NativeSessionRecord(pid: 2, sessionId: "s", cwd: "/a", name: nil, state: .idle, waitingFor: nil,
                                statusChangedAt: Date(timeIntervalSince1970: 5)),
        ]
        let sessions = SessionMerger.merge(native: native, hooks: [], isAlive: { _, _ in true })
        #expect(Set(sessions.map(\.id)).count == 2)
        var memory = SessionMemory()
        _ = memory.advance(to: sessions, isAlive: { _ in true })
        #expect(memory.advance(to: sessions, isAlive: { _ in true }).isEmpty)
    }

    @Test func reusedPidIsNotTheSameSession() {
        let native = [NativeSessionRecord(pid: 9, sessionId: "s", cwd: "/a", name: nil, state: .working, waitingFor: nil,
                                          statusChangedAt: Date(timeIntervalSince1970: 100))]
        let started = Date(timeIntervalSince1970: 500)
        let sessions = SessionMerger.merge(native: native, hooks: [],
                                           isAlive: { _, seen in seen.map { started <= $0 } ?? true })
        #expect(sessions.isEmpty)
    }

    @Test func gitBranchSurvivesDotDotPaths() throws {
        let dir = try TempDir()
        try dir.write("ref: refs/heads/main\n", to: "repo/.git/HEAD")
        try FileManager.default.createDirectory(at: dir.url.appending(path: "other"), withIntermediateDirectories: true)
        #expect(GitBranch.current(in: dir.url.path + "/other/../repo") == "main")
        #expect(GitBranch.current(in: "/nonexistent/a/../b") == nil)
    }
}

@Suite struct InstallerSafetyTests {
    let dir: TempDir
    let installer: Installer

    init() throws {
        dir = try TempDir()
        try dir.write("#!/bin/sh\n", to: "helper-src")
        installer = Installer(paths: dir.paths, helperSource: dir.url.appending(path: "helper-src"))
    }

    @Test func symlinkedSettingsAreEditedInPlace() throws {
        try dir.write(#"{"theme":"dark"}"#, to: "dotfiles/settings.json")
        let target = dir.url.appending(path: "dotfiles/settings.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: dir.paths.settingsFile, withDestinationURL: target)
        try installer.install()
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: dir.paths.settingsFile.path)
        #expect(link == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8).contains("statusLine"))
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func unchangedSettingsAreNotRewrittenAndBackupsAreCapped() throws {
        try dir.write(#"{"theme":"dark"}"#, to: "settings.json")
        try installer.install()
        let before = try FileManager.default.attributesOfItem(atPath: dir.paths.settingsFile.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 1.1)
        try installer.install()
        let after = try FileManager.default.attributesOfItem(atPath: dir.paths.settingsFile.path)[.modificationDate] as? Date
        #expect(before == after)
        for _ in 0..<3 {
            try installer.uninstall()
            Thread.sleep(forTimeInterval: 1.1)
            try installer.install()
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
            .filter { $0.hasPrefix("settings.json.clawdmeter-backup-") }
        #expect(backups.count <= 2)
    }

    @Test func uninstallKeepsHelperAndHistoryForOpenSessions() throws {
        try installer.install()
        try dir.write("[]", to: "clawdmeter/history.json")
        try dir.write("{}", to: "clawdmeter/limits.json")
        try installer.uninstall()
        #expect(FileManager.default.isExecutableFile(atPath: dir.paths.helperPath.path))
        #expect(FileManager.default.fileExists(atPath: dir.paths.appDir.appending(path: "history.json").path))
    }
}
