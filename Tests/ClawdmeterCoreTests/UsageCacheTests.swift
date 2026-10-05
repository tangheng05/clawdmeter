import Foundation
import Testing
@testable import ClawdmeterCore

@Suite struct UsageCacheTests {
    let cache = """
    {"oauthAccount":{"accountUuid":"acct-a"},
     "cachedUsageUtilization":{"fetchedAtMs":1791113235888,"accountUuid":"acct-a",
       "utilization":{"five_hour":{"utilization":14,"resets_at":"2026-10-04T15:59:59.664258+00:00"},
                      "seven_day":{"utilization":87,"resets_at":"2026-10-05T08:59:59.664275+00:00"},
                      "seven_day_opus":null}}}
    """

    @Test func readsClaudeCodesOwnUsageCache() throws {
        let dir = try TempDir()
        try dir.write(cache, to: ".claude.json")
        let snapshot = Account.read(dir.paths)
        #expect(snapshot.account == "acct-a")
        let limits = try #require(snapshot.cachedLimits)
        #expect(limits.fiveHour?.usedPercentage == 14)
        #expect(limits.sevenDay?.usedPercentage == 87)
        #expect(limits.account == "acct-a")
        #expect(limits.updatedAt == Date(timeIntervalSince1970: 1_791_113_235.888))
        let reset = try #require(limits.fiveHour?.resetsAt)
        #expect(abs(reset.timeIntervalSince1970 - 1_791_129_599.664) < 0.01)
    }

    @Test func missingCacheIsNil() throws {
        let dir = try TempDir()
        try dir.write(#"{"oauthAccount":{"accountUuid":"acct-a"}}"#, to: ".claude.json")
        #expect(Account.read(dir.paths).cachedLimits == nil)
    }

    @Test func newestSourceWins() {
        let old = RateLimits(fiveHour: LimitWindow(usedPercentage: 10, resetsAt: nil), sevenDay: nil,
                             updatedAt: Date(timeIntervalSince1970: 100))
        let new = RateLimits(fiveHour: LimitWindow(usedPercentage: 20, resetsAt: nil), sevenDay: nil,
                             updatedAt: Date(timeIntervalSince1970: 200))
        #expect(RateLimits.newest(old, new) == new)
        #expect(RateLimits.newest(new, old) == new)
        #expect(RateLimits.newest(nil, old) == old)
        #expect(RateLimits.newest(nil, nil) == nil)
    }

    @Test func disconnectKeepsUsageData() throws {
        let dir = try TempDir()
        try dir.write("#!/bin/sh\n", to: "helper-src")
        let installer = Installer(paths: dir.paths, helperSource: dir.url.appending(path: "helper-src"))
        try installer.install()
        try dir.write(#"{"ts":1,"rate_limits":{"five_hour":{"used_percentage":5}}}"#, to: "clawdmeter/limits.json")
        try dir.write(#"{"used":40}"#, to: "clawdmeter/context/s.json")
        try installer.uninstall()
        #expect(FileManager.default.fileExists(atPath: dir.paths.limitsFile.path))
        #expect(FileManager.default.fileExists(atPath: dir.paths.contextDir.appending(path: "s.json").path))
    }
}
