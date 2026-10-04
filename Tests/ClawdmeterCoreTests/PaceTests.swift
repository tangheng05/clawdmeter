import Foundation
import Testing
@testable import ClawdmeterCore

@Suite struct PaceTests {
    let day: TimeInterval = 86_400
    var now: Date { Date(timeIntervalSince1970: 1_000_000) }

    func window(_ used: Double, resetIn days: Double) -> LimitWindow {
        LimitWindow(usedPercentage: used, resetsAt: now.addingTimeInterval(days * day))
    }

    @Test func overPaceHitsLimit() {
        // 2 days into the week at 60% → 100% after 3.33 days.
        let forecast = Pace.forecast(window(60, resetIn: 5), now: now)
        let start = now.addingTimeInterval(-2 * day)
        #expect(forecast == .hitsLimit(at: start.addingTimeInterval(2 * day * 100 / 60)))
    }

    @Test func underPaceProjectsAtReset() {
        #expect(Pace.forecast(window(20, resetIn: 5), now: now) == .onTrack(projected: 70))
    }

    @Test func tooEarlyOrTooLittleIsHidden() {
        #expect(Pace.forecast(window(30, resetIn: 6.9), now: now) == nil)
        #expect(Pace.forecast(window(3, resetIn: 4), now: now) == nil)
        #expect(Pace.forecast(window(100, resetIn: 4), now: now) == nil)
    }
}

@Suite struct UsageHistoryTests {
    func limits(_ week: Double) -> RateLimits {
        RateLimits(fiveHour: LimitWindow(usedPercentage: 1, resetsAt: nil),
                   sevenDay: LimitWindow(usedPercentage: week, resetsAt: nil), updatedAt: .now)
    }

    @Test func recordsOnlyChangesAndPrunes() throws {
        let dir = try TempDir()
        let history = UsageHistory(file: dir.url.appending(path: "h.json"))
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        history.record(limits(10), now: t0)
        history.record(limits(10), now: t0.addingTimeInterval(60))
        history.record(limits(12), now: t0.addingTimeInterval(120))
        #expect(history.load().count == 2)
        history.record(limits(13), now: t0.addingTimeInterval(9 * 86_400))
        #expect(history.load().map(\.week) == [13])
    }

    @Test func corruptFileIsIgnored() throws {
        let dir = try TempDir()
        try dir.write("nope", to: "h.json")
        let history = UsageHistory(file: dir.url.appending(path: "h.json"))
        #expect(history.load().isEmpty)
        history.record(limits(5), now: .now)
        #expect(history.load().count == 1)
    }

    @Test func dailyUsageHandlesResets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_000_000))
        let samples = [
            UsageHistory.Sample(ts: today.addingTimeInterval(-86_400 + 3600).timeIntervalSince1970, week: 10),
            UsageHistory.Sample(ts: today.addingTimeInterval(-86_400 + 7200).timeIntervalSince1970, week: 25),
            UsageHistory.Sample(ts: today.addingTimeInterval(3600).timeIntervalSince1970, week: 30),
            UsageHistory.Sample(ts: today.addingTimeInterval(7200).timeIntervalSince1970, week: 4),
        ]
        let days = UsageHistory.dailyUsage(samples, days: 3, now: today.addingTimeInterval(10_000), calendar: calendar)
        #expect(days.map(\.amount) == [0, 15, 9])
        #expect(days.last?.date == today)
    }
}
