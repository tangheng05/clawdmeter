import Foundation
import Testing
@testable import ClawdmeterCore

@Suite struct SpendTests {
    // Close to the real time, since only recently modified logs are read.
    let now = Date.now
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Phnom_Penh")!
        return calendar
    }

    func line(id: String, model: String = "claude-opus-5-5", at date: Date, input: Int = 0, output: Int = 0,
              read: Int = 0, write5m: Int = 0, write1h: Int = 0, speed: String? = nil) -> String {
        let iso = ISO8601DateFormatter().string(from: date)
        let speedField = speed.map { #","speed":"\#($0)""# } ?? ""
        return #"{"type":"assistant","timestamp":"\#(iso)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(write5m + write1h),"cache_creation":{"ephemeral_5m_input_tokens":\#(write5m),"ephemeral_1h_input_tokens":\#(write1h)}\#(speedField)}}}"#
    }

    @Test func pricesEveryTokenKind() {
        let price = ModelPrice.lookup("claude-opus-5-5")!
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                               cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
        // 4 + 20 + 0.20 + 4×1.25 + 4×2
        #expect(abs(price.cost(of: usage) - 37.2) < 0.0001)
    }

    @Test func longestModelPrefixWins() {
        #expect(ModelPrice.lookup("claude-opus-5-5")?.input == 4)
        #expect(ModelPrice.lookup("claude-opus-5")?.input == 5)
        #expect(ModelPrice.lookup("claude-fable-5-1")?.cacheRead == 0.25)
        #expect(ModelPrice.lookup("claude-fable-5")?.cacheRead == 1)
        #expect(ModelPrice.lookup("anthropic.claude-sonnet-4-6")?.input == 3)
        #expect(ModelPrice.lookup("gpt-5") == nil)
        #expect(ModelPrice.lookup("<synthetic>") == nil)
    }

    @Test func repeatedLinesForOneReplyCountOnce() throws {
        let dir = try TempDir()
        let reply = line(id: "msg_1", at: now, input: 100, output: 50)
        try dir.write([reply, reply, reply].joined(separator: "\n") + "\n", to: "projects/p/s.jsonl")
        let summary = SpendIndex(paths: dir.paths).refresh(now: now, calendar: calendar)
        #expect(summary.today.tokens == 150)
    }

    @Test func aReplyThatGrowsAcrossLinesCountsItsFinalSize() throws {
        let dir = try TempDir()
        try dir.write([line(id: "msg_1", at: now, output: 16), line(id: "msg_1", at: now, output: 160)].joined(separator: "\n") + "\n",
                      to: "projects/p/a.jsonl")
        try dir.write(line(id: "msg_1", at: now, output: 16) + "\n", to: "projects/p/b.jsonl")
        #expect(SpendIndex(paths: dir.paths).refresh(now: now, calendar: calendar).today.tokens == 160)
    }

    @Test func repliesCopiedIntoAResumedSessionCountOnce() throws {
        let dir = try TempDir()
        let reply = line(id: "msg_1", at: now, output: 10)
        try dir.write(reply + "\n", to: "projects/p/a.jsonl")
        try dir.write(reply + "\n" + line(id: "msg_2", at: now, output: 5) + "\n", to: "projects/p/b.jsonl")
        #expect(SpendIndex(paths: dir.paths).refresh(now: now, calendar: calendar).today.tokens == 15)
    }

    @Test func bucketsByLocalDay() throws {
        let dir = try TempDir()
        let today = calendar.startOfDay(for: now)
        try dir.write([
            line(id: "a", at: today.addingTimeInterval(60), output: 1),
            line(id: "b", at: today.addingTimeInterval(-60), output: 10),
            line(id: "c", at: today.addingTimeInterval(-20 * 86_400), output: 100),
            line(id: "d", at: today.addingTimeInterval(-40 * 86_400), output: 1000),
        ].joined(separator: "\n") + "\n", to: "projects/p/s.jsonl")
        let summary = SpendIndex(paths: dir.paths).refresh(now: now, calendar: calendar)
        #expect(summary.today.tokens == 1)
        #expect(summary.yesterday.tokens == 10)
        #expect(summary.last30.tokens == 111)
    }

    @Test func readsOnlyNewLinesAfterARefresh() throws {
        let dir = try TempDir()
        let file = dir.url.appending(path: "projects/p/s.jsonl")
        try dir.write(line(id: "a", at: now, output: 1) + "\n", to: "projects/p/s.jsonl")
        let index = SpendIndex(paths: dir.paths)
        #expect(index.refresh(now: now, calendar: calendar).today.tokens == 1)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        // A half-written line waits until it's complete.
        try handle.write(contentsOf: Data((line(id: "b", at: now, output: 2) + "\n" + #"{"type":"assist"#).utf8))
        #expect(index.refresh(now: now, calendar: calendar).today.tokens == 3)
        try handle.write(contentsOf: Data(#"ant"}"#.utf8) + Data("\n".utf8) + Data((line(id: "c", at: now, output: 4) + "\n").utf8))
        try handle.close()
        #expect(index.refresh(now: now, calendar: calendar).today.tokens == 7)
    }

    @Test func aRewrittenFileIsReadAgain() throws {
        let dir = try TempDir()
        try dir.write([line(id: "a", at: now, output: 5), line(id: "b", at: now, output: 5)].joined(separator: "\n") + "\n",
                      to: "projects/p/s.jsonl")
        let index = SpendIndex(paths: dir.paths)
        #expect(index.refresh(now: now, calendar: calendar).today.tokens == 10)
        try dir.write(line(id: "c", at: now, output: 1) + "\n", to: "projects/p/s.jsonl")
        #expect(index.refresh(now: now, calendar: calendar).today.tokens == 1)
    }

    @Test func handlesALineLongerThanTheReadBuffer() throws {
        let dir = try TempDir()
        let filler = #"{"type":"user","text":""# + String(repeating: "x", count: 3 << 20) + #""}"#
        try dir.write([line(id: "a", at: now, output: 1), filler, line(id: "b", at: now, output: 2)].joined(separator: "\n") + "\n",
                      to: "projects/p/s.jsonl")
        #expect(SpendIndex(paths: dir.paths).refresh(now: now, calendar: calendar).today.tokens == 3)
    }

    @Test func includesSubagentLogs() throws {
        let dir = try TempDir()
        try dir.write(line(id: "a", at: now, output: 1) + "\n", to: "projects/p/s.jsonl")
        try dir.write(line(id: "b", at: now, output: 2) + "\n", to: "projects/p/s/subagents/agent-1.jsonl")
        #expect(SpendIndex(paths: dir.paths).refresh(now: now, calendar: calendar).today.tokens == 3)
    }

    @Test func unknownModelsCountTokensButNoCost() throws {
        let dir = try TempDir()
        try dir.write(line(id: "a", model: "claude-next-9", at: now, output: 1_000_000) + "\n", to: "projects/p/s.jsonl")
        let summary = SpendIndex(paths: dir.paths).refresh(now: now, calendar: calendar)
        #expect(summary.today.tokens == 1_000_000)
        #expect(summary.today.cost == 0)
        #expect(summary.hasUnpriced)
    }

    @Test func fastModeCostsDouble() throws {
        let dir = try TempDir()
        try dir.write(line(id: "a", at: now, output: 1_000_000, speed: "fast") + "\n", to: "projects/p/s.jsonl")
        #expect(abs(SpendIndex(paths: dir.paths).refresh(now: now, calendar: calendar).today.cost - 40) < 0.0001)
    }

    @Test func olderLogsWithoutTheCacheBreakdownCountAsFiveMinuteWrites() throws {
        let dir = try TempDir()
        let iso = ISO8601DateFormatter().string(from: now)
        try dir.write(#"{"type":"assistant","timestamp":"\#(iso)","message":{"id":"a","model":"claude-opus-5-5","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":1000000}}}"# + "\n",
                      to: "projects/p/s.jsonl")
        #expect(abs(SpendIndex(paths: dir.paths).refresh(now: now, calendar: calendar).today.cost - 5) < 0.0001)
    }
}
