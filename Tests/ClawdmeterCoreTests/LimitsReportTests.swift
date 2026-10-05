import Foundation
import Testing
@testable import ClawdmeterCore

@Suite struct LimitsReportTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func limits(_ used: Double, at updated: TimeInterval, account: String?) -> RateLimits {
        RateLimits(fiveHour: LimitWindow(usedPercentage: used, resetsAt: now.addingTimeInterval(3600)),
                   sevenDay: nil, updatedAt: now.addingTimeInterval(updated), account: account)
    }

    @Test func bestPicksTheNewestForTheSignedInAccount() {
        let status = limits(10, at: -60, account: "a")
        let cached = limits(20, at: -10, account: "a")
        #expect(RateLimits.best(status, cached: cached, account: "a")?.fiveHour?.usedPercentage == 20)
        #expect(RateLimits.best(status, cached: limits(90, at: 0, account: "b"), account: "a")?.fiveHour?.usedPercentage == 10)
        #expect(RateLimits.best(nil, cached: nil, account: "a") == nil)
    }

    @Test func bestReadsBothSourcesFromDisk() throws {
        let dir = try TempDir()
        try dir.write(#"{"oauthAccount":{"accountUuid":"a","organizationType":"claude_pro"}}"#, to: ".claude.json")
        try dir.write(#"{"ts":\#(now.timeIntervalSince1970),"account":"a","rate_limits":{"five_hour":{"used_percentage":33,"resets_at":\#(now.timeIntervalSince1970 + 3600)}}}"#,
                      to: "clawdmeter/limits.json")
        #expect(RateLimits.best(paths: dir.paths)?.fiveHour?.usedPercentage == 33)
    }

    @Test func reportJSON() throws {
        let snapshot = AccountSnapshot(account: "a", cachedLimits: nil, plan: "Pro")
        let expired = RateLimits(fiveHour: LimitWindow(usedPercentage: 80, resetsAt: now.addingTimeInterval(-1)),
                                 sevenDay: LimitWindow(usedPercentage: 33.5, resetsAt: now.addingTimeInterval(86_400)),
                                 updatedAt: now.addingTimeInterval(-60), account: "a")
        let report = LimitsReport(limits: expired, snapshot: snapshot, now: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(report), as: UTF8.self)
        // An expired window reads as 0% used, since it has reset.
        #expect(json == #"{"account":"a","fiveHour":{"leftPercent":100,"usedPercent":0},"plan":"Pro","sevenDay":{"leftPercent":66.5,"resetsAt":"2027-01-16T08:00:00Z","usedPercent":33.5},"stale":false,"updatedAt":"2027-01-15T07:59:00Z"}"#)
    }

    @Test func reportWithoutLimits() throws {
        let report = LimitsReport(limits: nil, snapshot: AccountSnapshot(account: nil, cachedLimits: nil), now: now)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(json == #"{"stale":true}"#)
    }
}
