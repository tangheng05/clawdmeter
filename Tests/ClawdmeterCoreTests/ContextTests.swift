import Foundation
import Testing
@testable import ClawdmeterCore

@Suite struct ContextTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func payload(_ sid: String, _ used: Double) -> Data {
        Data(#"{"session_id":"\#(sid)","context_window":{"used_percentage":\#(used),"context_window_size":200000}}"#.utf8)
    }

    @Test func statuslineRecordsContextPerSession() throws {
        let dir = try TempDir()
        _ = StatuslineHandler.handle(input: payload("s1", 62.4), paths: dir.paths, now: now, runPrevious: { _, _ in nil })
        _ = StatuslineHandler.handle(input: payload("s2", 10), paths: dir.paths, now: now, runPrevious: { _, _ in nil })
        let usage = ContextReader.read(dir.paths)
        #expect(usage["s1"] == 62.4)
        #expect(usage["s2"] == 10)
    }

    @Test func unchangedContextIsNotRewritten() throws {
        let dir = try TempDir()
        _ = StatuslineHandler.handle(input: payload("s1", 50), paths: dir.paths, now: now, runPrevious: { _, _ in nil })
        let file = dir.paths.contextDir.appending(path: "s1.json")
        let first = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 1.1)
        _ = StatuslineHandler.handle(input: payload("s1", 50), paths: dir.paths, now: now, runPrevious: { _, _ in nil })
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == first)
    }

    @Test func oldContextFilesAreCleanedUp() throws {
        let dir = try TempDir()
        try dir.write(#"{"used":40}"#, to: "clawdmeter/context/old.json")
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-90_000)],
                                              ofItemAtPath: dir.paths.contextDir.appending(path: "old.json").path)
        #expect(ContextReader.read(dir.paths).isEmpty)
    }

    @Test func mergerAttachesContextBySessionId() {
        let native = [NativeSessionRecord(pid: 1, sessionId: "s1", cwd: "/a", name: nil, state: .idle, waitingFor: nil,
                                          statusChangedAt: now)]
        let sessions = SessionMerger.merge(native: native, hooks: [], context: ["s1": 71], isAlive: { _, _ in true })
        #expect(sessions.first?.contextUsed == 71)
    }

    @Test func malformedSessionIdIsIgnored() throws {
        let dir = try TempDir()
        _ = StatuslineHandler.handle(input: payload("../x", 5), paths: dir.paths, now: now, runPrevious: { _, _ in nil })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.paths.contextDir.path)) ?? []
        #expect(files == ["x.json"])
    }
}

@Suite struct CompactingTests {
    let at = Date(timeIntervalSince1970: 1_000)

    func native(_ state: SessionState) -> [NativeSessionRecord] {
        [NativeSessionRecord(pid: 1, sessionId: "s", cwd: "/a", name: nil, state: state, waitingFor: nil, statusChangedAt: at)]
    }

    func hook(_ event: String) -> [HookRecord] {
        [HookRecord(sessionId: "s", event: event, tool: nil, cwd: "/a", pid: 1, at: at.addingTimeInterval(1))]
    }

    @Test func preCompactWhileBusyIsCompacting() {
        let s = SessionMerger.merge(native: native(.working), hooks: hook("PreCompact"), isAlive: { _, _ in true })
        #expect(s.first?.compacting == true)
        #expect(s.first?.state == .working)
    }

    @Test func compactionEndsWithTheNextEvent() {
        let s = SessionMerger.merge(native: native(.working), hooks: hook("SessionStart"), isAlive: { _, _ in true })
        #expect(s.first?.compacting == false)
        let idle = SessionMerger.merge(native: native(.idle), hooks: hook("PreCompact"), isAlive: { _, _ in true })
        #expect(idle.first?.compacting == false)
    }

    @Test func installerRegistersPreCompact() {
        #expect(Installer.hookEvents.contains("PreCompact"))
    }
}
