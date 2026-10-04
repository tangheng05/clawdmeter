import Foundation
import Testing
@testable import ClawdmeterCore

@Suite struct NativeSessionReaderTests {
    @Test func decodesFullRecord() throws {
        let dir = try TempDir()
        try dir.write("""
        {"pid":2017,"sessionId":"s1","cwd":"/a/proj","name":"proj-df","status":"busy","kind":"interactive",
         "updatedAt":1791110433134,"statusUpdatedAt":1791110433000,"somethingNew":[1,2]}
        """, to: "sessions/2017.json")
        let records = NativeSessionReader.read(dir.paths)
        #expect(records.count == 1)
        let r = try #require(records.first)
        #expect(r.pid == 2017)
        #expect(r.sessionId == "s1")
        #expect(r.state == .working)
        #expect(r.statusChangedAt == Date(timeIntervalSince1970: 1791110433))
    }

    @Test func waitingForMeansWaiting() throws {
        let dir = try TempDir()
        try dir.write(#"{"pid":5,"status":"busy","waitingFor":"dialog open"}"#, to: "sessions/5.json")
        let r = try #require(NativeSessionReader.read(dir.paths).first)
        #expect(r.state == .waiting)
        #expect(r.waitingFor == "dialog open")
    }

    @Test func idleAndMissingStatus() throws {
        let dir = try TempDir()
        try dir.write(#"{"pid":5,"status":"idle"}"#, to: "sessions/5.json")
        try dir.write(#"{"pid":6}"#, to: "sessions/6.json")
        let records = NativeSessionReader.read(dir.paths).sorted { $0.pid < $1.pid }
        #expect(records.map(\.state) == [.idle, nil])
    }

    @Test func skipsTruncatedAndForeignFiles() throws {
        let dir = try TempDir()
        try dir.write(#"{"pid":5,"stat"#, to: "sessions/5.json")
        try dir.write("garbage", to: "sessions/2017.key")
        #expect(NativeSessionReader.read(dir.paths).isEmpty)
    }

    @Test func missingDirectoryIsEmpty() throws {
        let dir = try TempDir()
        #expect(NativeSessionReader.read(dir.paths).isEmpty)
    }
}

@Suite struct HookStateReaderTests {
    @Test func decodesAndMapsEvents() throws {
        let dir = try TempDir()
        try dir.write(#"{"sessionId":"s1","event":"PreToolUse","tool":"Edit","cwd":"/a","pid":9,"ts":100}"#,
                      to: "clawdmeter/hooks/s1.json")
        try dir.write(#"{"sessionId":"s2","event":"PermissionRequest","pid":10,"ts":100}"#,
                      to: "clawdmeter/hooks/s2.json")
        try dir.write(#"{"sessionId":"s3","event":"Stop","pid":11,"ts":100}"#, to: "clawdmeter/hooks/s3.json")
        let byId = Dictionary(uniqueKeysWithValues: HookStateReader.read(dir.paths).map { ($0.sessionId, $0) })
        #expect(byId["s1"]?.state == .working)
        #expect(byId["s1"]?.tool == "Edit")
        #expect(byId["s2"]?.state == .waiting)
        #expect(byId["s3"]?.state == .idle)
    }

    @Test func deletesFilesOlderThanADay() throws {
        let dir = try TempDir()
        try dir.write(#"{"sessionId":"old","event":"Stop","ts":1}"#, to: "clawdmeter/hooks/old.json")
        let file = dir.url.appending(path: "clawdmeter/hooks/old.json")
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-90_000)],
                                              ofItemAtPath: file.path)
        #expect(HookStateReader.read(dir.paths).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

@Suite struct LimitsReaderTests {
    @Test func decodesWindows() throws {
        let dir = try TempDir()
        try dir.write("""
        {"ts":1000,"rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":2000},
         "seven_day":{"used_percentage":17,"resets_at":3000000}}}
        """, to: "clawdmeter/limits.json")
        let limits = try #require(LimitsReader.read(dir.paths))
        #expect(limits.fiveHour == LimitWindow(usedPercentage: 42.5, resetsAt: Date(timeIntervalSince1970: 2000)))
        #expect(limits.sevenDay?.usedPercentage == 17)
        #expect(limits.updatedAt == Date(timeIntervalSince1970: 1000))
    }

    @Test func acceptsMillisecondResets() throws {
        let dir = try TempDir()
        try dir.write(#"{"ts":1,"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":1791120000000}}}"#,
                      to: "clawdmeter/limits.json")
        let limits = try #require(LimitsReader.read(dir.paths))
        #expect(limits.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1791120000))
    }

    @Test func missingOrNullIsNil() throws {
        let dir = try TempDir()
        #expect(LimitsReader.read(dir.paths) == nil)
        try dir.write(#"{"ts":1,"rate_limits":null}"#, to: "clawdmeter/limits.json")
        #expect(LimitsReader.read(dir.paths) == nil)
    }

    @Test func staleness() {
        let limits = RateLimits(fiveHour: nil, sevenDay: nil, updatedAt: Date(timeIntervalSince1970: 0))
        #expect(!limits.isStale(now: Date(timeIntervalSince1970: 600)))
        #expect(limits.isStale(now: Date(timeIntervalSince1970: 601)))
    }
}

@Suite struct SessionMergerTests {
    let t0 = Date(timeIntervalSince1970: 1000)

    func native(_ pid: Int32, _ id: String?, _ state: SessionState?, waitingFor: String? = nil,
                at: TimeInterval = 1000) -> NativeSessionRecord {
        NativeSessionRecord(pid: pid, sessionId: id, cwd: "/p/\(pid)", name: nil, state: state,
                            waitingFor: waitingFor, statusChangedAt: Date(timeIntervalSince1970: at))
    }

    func hook(_ id: String, _ event: String, pid: Int32? = nil, tool: String? = nil,
              at: TimeInterval = 1000) -> HookRecord {
        HookRecord(sessionId: id, event: event, tool: tool, cwd: "/h/\(id)", pid: pid,
                   at: Date(timeIntervalSince1970: at))
    }

    @Test func nativeOnly() {
        let s = SessionMerger.merge(native: [native(1, "a", .working)], hooks: [], isAlive: { _ in true })
        #expect(s.map(\.id) == ["a"])
        #expect(s.first?.state == .working)
        #expect(s.first?.cwd == "/p/1")
    }

    @Test func nativeStateWinsAndHookAddsTool() {
        let s = SessionMerger.merge(native: [native(1, "a", .working)],
                                    hooks: [hook("a", "PreToolUse", tool: "Bash", at: 1001)],
                                    isAlive: { _ in true })
        #expect(s.first?.state == .working)
        #expect(s.first?.tool == "Bash")
    }

    @Test func toolHiddenWhenNotWorking() {
        let s = SessionMerger.merge(native: [native(1, "a", .idle)],
                                    hooks: [hook("a", "PreToolUse", tool: "Bash")], isAlive: { _ in true })
        #expect(s.first?.tool == nil)
    }

    @Test func hookFillsMissingNativeStatus() {
        let s = SessionMerger.merge(native: [native(1, "a", nil)],
                                    hooks: [hook("a", "PermissionRequest", at: 1005)], isAlive: { _ in true })
        #expect(s.first?.state == .waiting)
        #expect(s.first?.since == Date(timeIntervalSince1970: 1005))
    }

    @Test func hookOnlySessionNeedsLivePid() {
        let s = SessionMerger.merge(native: [],
                                    hooks: [hook("a", "UserPromptSubmit", pid: 7), hook("b", "Stop"),
                                            hook("c", "Stop", pid: 8)],
                                    isAlive: { $0 == 7 })
        #expect(s.map(\.id) == ["a"])
        #expect(s.first?.state == .working)
    }

    @Test func deadPidsDropped() {
        let s = SessionMerger.merge(native: [native(1, "a", .working), native(2, "b", .idle)], hooks: [],
                                    isAlive: { $0 == 2 })
        #expect(s.map(\.id) == ["b"])
    }

    @Test func missingSessionIdFallsBackToPid() {
        let s = SessionMerger.merge(native: [native(3, nil, .idle)], hooks: [], isAlive: { _ in true })
        #expect(s.first?.id == "pid-3")
    }

    @Test func sortedByPriorityThenRecency() {
        let s = SessionMerger.merge(
            native: [native(1, "idle", .idle, at: 5000), native(2, "old", .working, at: 1000),
                     native(3, "new", .working, at: 2000), native(4, "wait", .waiting, waitingFor: "x")],
            hooks: [], isAlive: { _ in true })
        #expect(s.map(\.id) == ["wait", "new", "old", "idle"])
    }

    @Test func aggregate() {
        #expect(Aggregate(sessions: []).state == .idle)
        let s = SessionMerger.merge(native: [native(1, "a", .working), native(2, "b", .waiting)], hooks: [],
                                    isAlive: { _ in true })
        let agg = Aggregate(sessions: s)
        #expect(agg.state == .waiting)
        #expect(agg.count == 2)
    }
}
