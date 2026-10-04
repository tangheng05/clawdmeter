import Foundation
import Testing
@testable import ClawdmeterCore

@Suite struct TranscriptTests {
    func assistant(_ model: String, input: Int, cacheRead: Int, cacheCreate: Int) -> String {
        #"{"type":"assistant","message":{"model":"\#(model)","usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheCreate),"output_tokens":30}}}"#
    }

    @Test func statuslineLearnsModelWindowSizes() throws {
        let dir = try TempDir()
        let payload = #"{"session_id":"s","model":{"id":"claude-opus-5-5","display_name":"Opus"},"context_window":{"used_percentage":10,"context_window_size":200000}}"#
        _ = StatuslineHandler.handle(input: Data(payload.utf8), paths: dir.paths, runPrevious: { _, _ in nil })
        #expect(ContextWindows.load(dir.paths) == ["claude-opus-5-5": 200_000])
    }

    @Test func readsLatestUsageFromTranscript() throws {
        let dir = try TempDir()
        let lines = [
            #"{"type":"user","message":{"content":"hi"}}"#,
            assistant("claude-opus-5-5", input: 5, cacheRead: 1000, cacheCreate: 10),
            #"{"type":"user","message":{"content":"more"}}"#,
            assistant("claude-opus-5-5", input: 2, cacheRead: 36154, cacheCreate: 151),
            #"{"type":"assistant","message":{"content":[]}}"#,
            #"{"type":"user","mess"#,
        ]
        try dir.write(lines.joined(separator: "\n"), to: "projects/-w-serey/s1.jsonl")
        let usage = try #require(TranscriptUsage.latest(in: dir.url.appending(path: "projects/-w-serey/s1.jsonl")))
        #expect(usage.tokens == 36_307)
        #expect(usage.model == "claude-opus-5-5")
    }

    @Test func cacheFindsTranscriptAndComputesPercentWhenWindowKnown() throws {
        let dir = try TempDir()
        try dir.write(assistant("claude-opus-5-5", input: 0, cacheRead: 50_000, cacheCreate: 0), to: "projects/-w-a/s1.jsonl")
        let cache = TranscriptCache(paths: dir.paths)
        let unknown = try #require(cache.context(forSession: "s1", windows: [:]))
        #expect(unknown.tokens == 50_000)
        #expect(unknown.percent == nil)
        let known = try #require(cache.context(forSession: "s1", windows: ["claude-opus-5-5": 200_000]))
        #expect(known.percent == 25)
        #expect(cache.context(forSession: "missing", windows: [:]) == nil)
    }

    @Test func mergerPrefersStatuslinePercentThenTranscript() {
        let native = [
            NativeSessionRecord(pid: 1, sessionId: "term", cwd: "/a", name: nil, state: .idle, waitingFor: nil, statusChangedAt: .now),
            NativeSessionRecord(pid: 2, sessionId: "code", cwd: "/b", name: nil, state: .idle, waitingFor: nil, statusChangedAt: .now),
        ]
        let sessions = SessionMerger.merge(native: native, hooks: [], context: ["term": 61],
                                           transcript: { $0 == "code" ? TranscriptContext(tokens: 36_000, percent: nil) : nil },
                                           isAlive: { _, _ in true })
        let term = sessions.first { $0.sessionId == "term" }
        let code = sessions.first { $0.sessionId == "code" }
        #expect(term?.contextUsed == 61)
        #expect(code?.contextUsed == nil)
        #expect(code?.contextTokens == 36_000)
    }
}
