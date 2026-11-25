import Foundation
import Testing
@testable import ClawdmeterCore

@Suite struct UsageAPITests {
    let now = Date(timeIntervalSince1970: 1_791_800_000)

    @Test func parsesUsageResponse() throws {
        let body = #"{"five_hour":{"utilization":33.0,"resets_at":"2026-10-12T20:30:00.277939+00:00"},"seven_day":{"utilization":15.0,"resets_at":null},"seven_day_opus":null}"#
        let limits = try #require(UsageAPI.parse(Data(body.utf8), account: "acct-a", now: now))
        #expect(limits.fiveHour?.usedPercentage == 33)
        #expect(limits.sevenDay?.usedPercentage == 15)
        #expect(limits.sevenDay?.resetsAt == nil)
        #expect(limits.account == "acct-a")
        #expect(limits.updatedAt == now)
    }

    @Test func aRejectedLoginIsToldApartFromAnOutage() {
        let body = Data(#"{"five_hour":{"utilization":5.0,"resets_at":null}}"#.utf8)
        #expect(UsageAPI.result(status: 401, data: Data(), account: nil, now: now) == .signedOut)
        #expect(UsageAPI.result(status: 500, data: Data(), account: nil, now: now) == .unavailable)
        #expect(UsageAPI.result(status: 200, data: body, account: "a", now: now)
                == .limits(RateLimits(fiveHour: LimitWindow(usedPercentage: 5, resetsAt: nil), sevenDay: nil, updatedAt: now, account: "a")))
    }

    @Test func emptyResponseIsNil() {
        #expect(UsageAPI.parse(Data(#"{"five_hour":null}"#.utf8), account: nil, now: now) == nil)
    }

    @Test func skipsExpiredToken() {
        func credentials(expiresAt: Double) -> Data {
            Data(#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":\#(Int(expiresAt))}}"#.utf8)
        }
        let ms = now.timeIntervalSince1970 * 1000
        #expect(UsageAPI.token(fromCredentials: credentials(expiresAt: ms + 60_000), now: now) == "tok")
        #expect(UsageAPI.token(fromCredentials: credentials(expiresAt: ms - 60_000), now: now) == nil)
    }

    @Test func aRecentFetchBeatsTheStatusLinesRepeatedNumbers() {
        func limits(_ used: Double, ago: TimeInterval) -> RateLimits {
            RateLimits(fiveHour: LimitWindow(usedPercentage: used, resetsAt: nil), sevenDay: nil,
                       updatedAt: now.addingTimeInterval(-ago), account: "a")
        }
        // An idle session keeps re-sending what it last saw, stamped as new.
        let best = RateLimits.best(limits(17, ago: 0), cached: nil, fetched: limits(25, ago: 30), account: "a", now: now)
        #expect(best?.fiveHour?.usedPercentage == 25)
        let old = RateLimits.best(limits(17, ago: 0), cached: nil, fetched: limits(25, ago: 600), account: "a", now: now)
        #expect(old?.fiveHour?.usedPercentage == 17)
    }

    @Test func fetchedSourceCountsWhenNewest() {
        func limits(_ used: Double, at ts: Double) -> RateLimits {
            RateLimits(fiveHour: LimitWindow(usedPercentage: used, resetsAt: nil), sevenDay: nil,
                       updatedAt: Date(timeIntervalSince1970: ts), account: "a")
        }
        let best = RateLimits.best(limits(10, at: 100), cached: limits(20, at: 200), fetched: limits(30, at: 300), account: "a")
        #expect(best?.fiveHour?.usedPercentage == 30)
    }
}
