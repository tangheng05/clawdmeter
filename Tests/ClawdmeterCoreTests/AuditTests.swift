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
        #expect(events == [.finished(sessionId: "a", name: "a", duration: 1_000)])
    }

    @Test func endedSessionsAreForgotten() {
        var memory = SessionMemory()
        _ = memory.advance(to: [session("a", .waiting, since: 9_000, pid: 7)], isAlive: { _ in true }, now: now)
        _ = memory.advance(to: [], isAlive: { _ in false }, now: now)
        #expect(memory.advance(to: [session("a", .waiting, since: 9_000, pid: 7)], isAlive: { _ in true }, now: now)
            == [.needsYou(sessionId: "a", name: "a")])
    }

    @Test func driftingResetTimeDoesNotRepeatAlerts() {
        var fired = Set<String>()
        func limits(reset: TimeInterval) -> RateLimits {
            RateLimits(fiveHour: LimitWindow(usedPercentage: 85, resetsAt: Date(timeIntervalSince1970: reset)),
                       sevenDay: nil, updatedAt: now)
        }
        #expect(EventDetector.limitEvents(old: nil, new: limits(reset: 36_000), fired: &fired).count == 1)
        #expect(EventDetector.limitEvents(old: nil, new: limits(reset: 36_001), fired: &fired).isEmpty)
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
        let now = Date(timeIntervalSince1970: 36_000)
        log.save(["5-hour-80-20", "Weekly-95-5"], now: now)
        #expect(log.load() == ["5-hour-80-20"])
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
