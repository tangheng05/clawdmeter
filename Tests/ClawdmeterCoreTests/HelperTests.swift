import Foundation
import Testing
@testable import ClawdmeterCore

@Suite struct HookHandlerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func writesRecord() throws {
        let dir = try TempDir()
        let input = #"{"session_id":"abc-1","tool_name":"Edit","cwd":"/a/proj","hook_event_name":"PreToolUse"}"#
        HookHandler.handle(event: "PreToolUse", input: Data(input.utf8), paths: dir.paths, parentPID: 42, now: now)
        let record = try #require(HookStateReader.read(dir.paths, now: .now).first)
        #expect(record == HookRecord(sessionId: "abc-1", event: "PreToolUse", tool: "Edit", cwd: "/a/proj",
                                     pid: 42, at: now))
    }

    @Test func sessionEndDeletes() throws {
        let dir = try TempDir()
        let input = Data(#"{"session_id":"abc"}"#.utf8)
        HookHandler.handle(event: "Stop", input: input, paths: dir.paths, parentPID: 1, now: now)
        HookHandler.handle(event: "SessionEnd", input: input, paths: dir.paths, parentPID: 1, now: now)
        #expect(HookStateReader.read(dir.paths).isEmpty)
    }

    @Test func garbageIsNoop() throws {
        let dir = try TempDir()
        HookHandler.handle(event: "Stop", input: Data("nope".utf8), paths: dir.paths, parentPID: 1, now: now)
        HookHandler.handle(event: "Stop", input: Data(#"{"cwd":"/a"}"#.utf8), paths: dir.paths, parentPID: 1, now: now)
        #expect(!FileManager.default.fileExists(atPath: dir.paths.hooksDir.path))
    }

    @Test func sessionIdIsSanitised() throws {
        let dir = try TempDir()
        HookHandler.handle(event: "Stop", input: Data(#"{"session_id":"../../evil"}"#.utf8), paths: dir.paths,
                           parentPID: 1, now: now)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.paths.hooksDir.path)
        #expect(files == ["evil.json"])
    }
}

@Suite struct StatuslineHandlerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payload = """
    {"model":{"display_name":"Opus"},"workspace":{"current_dir":"/a/proj"},
     "rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1800001000},
                    "seven_day":{"used_percentage":17.4,"resets_at":1800500000}}}
    """

    @Test func writesLimitsAndPrintsCompactLine() throws {
        let dir = try TempDir()
        let out = StatuslineHandler.handle(input: Data(payload.utf8), paths: dir.paths, now: now,
                                           runPrevious: { _, _ in Issue.record("should not run"); return nil })
        #expect(out == "Opus · proj · 5h 42% · wk 17%")
        let limits = try #require(LimitsReader.read(dir.paths))
        #expect(limits.fiveHour?.usedPercentage == 42)
        #expect(limits.updatedAt == now)
    }

    @Test func nullLimitsKeepsOldFile() throws {
        let dir = try TempDir()
        _ = StatuslineHandler.handle(input: Data(payload.utf8), paths: dir.paths, now: now, runPrevious: { _, _ in nil })
        let out = StatuslineHandler.handle(input: Data(#"{"model":{"display_name":"Opus"},"rate_limits":null}"#.utf8),
                                           paths: dir.paths, now: now.addingTimeInterval(60),
                                           runPrevious: { _, _ in nil })
        #expect(out == "Opus")
        #expect(LimitsReader.read(dir.paths)?.updatedAt == now)
    }

    @Test func passesThroughToPreviousCommand() throws {
        let dir = try TempDir()
        try dir.write("my-statusline --fancy\n", to: "clawdmeter/previous-statusline")
        var seen: (String, Data)?
        let out = StatuslineHandler.handle(input: Data(payload.utf8), paths: dir.paths, now: now,
                                           runPrevious: { cmd, data in seen = (cmd, data); return "theirs" })
        #expect(out == "theirs")
        #expect(seen?.0 == "my-statusline --fancy")
        #expect(seen?.1 == Data(payload.utf8))
        #expect(LimitsReader.read(dir.paths) != nil)
    }

    @Test func garbageInputPrintsNothing() throws {
        let dir = try TempDir()
        #expect(StatuslineHandler.handle(input: Data("x".utf8), paths: dir.paths, now: now,
                                         runPrevious: { _, _ in nil }) == "")
    }
}
