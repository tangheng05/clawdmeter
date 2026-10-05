import Foundation
import Testing
@testable import ClawdmeterCore

@Suite struct AccountTests {
    let payload = Data(#"{"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":1}}}"#.utf8)

    func signIn(_ dir: TempDir, _ uuid: String) throws {
        try dir.write(#"{"oauthAccount":{"accountUuid":"\#(uuid)","emailAddress":"x@y.z"},"other":1}"#, to: ".claude.json")
    }

    @Test func namesThePlan() throws {
        let dir = try TempDir()
        func plan(_ type: String, tier: String? = nil) throws -> String? {
            let tierField = tier.map { #","organizationRateLimitTier":"\#($0)""# } ?? ""
            try dir.write(#"{"oauthAccount":{"accountUuid":"a","organizationType":"\#(type)"\#(tierField)}}"#, to: ".claude.json")
            return Account.read(dir.paths).plan
        }
        #expect(try plan("claude_pro") == "Pro")
        #expect(try plan("claude_max", tier: "default_claude_max_5x") == "Max 5x")
        #expect(try plan("claude_max", tier: "default_claude_max_20x") == "Max 20x")
        #expect(try plan("claude_max") == "Max")
        #expect(try plan("claude_team") == "Team")
        #expect(try plan("claude_enterprise") == "Enterprise")
        #expect(try plan("something_new") == nil)
    }

    @Test func readsSignedInAccount() throws {
        let dir = try TempDir()
        #expect(Account.current(dir.paths) == nil)
        try signIn(dir, "acct-a")
        #expect(Account.current(dir.paths) == "acct-a")
    }

    @Test func limitsAreStampedWithTheAccount() throws {
        let dir = try TempDir()
        try signIn(dir, "acct-a")
        _ = StatuslineHandler.handle(input: payload, paths: dir.paths, runPrevious: { _, _ in nil })
        #expect(LimitsReader.read(dir.paths)?.account == "acct-a")
    }

    @Test func switchingAccountsRewritesLimitsRightAway() throws {
        let dir = try TempDir()
        let now = Date(timeIntervalSince1970: 1_000)
        try signIn(dir, "acct-a")
        _ = StatuslineHandler.handle(input: payload, paths: dir.paths, now: now, runPrevious: { _, _ in nil })
        try signIn(dir, "acct-b")
        _ = StatuslineHandler.handle(input: payload, paths: dir.paths, now: now.addingTimeInterval(5),
                                     runPrevious: { _, _ in nil })
        #expect(LimitsReader.read(dir.paths)?.account == "acct-b")
    }

    @Test func limitsFromAnotherAccountAreNotShown() {
        let limits = RateLimits(fiveHour: LimitWindow(usedPercentage: 97, resetsAt: nil), sevenDay: nil,
                                updatedAt: .now, account: "acct-a")
        #expect(limits.belongs(to: "acct-a"))
        #expect(!limits.belongs(to: "acct-b"))
        #expect(limits.belongs(to: nil))
        let unstamped = RateLimits(fiveHour: nil, sevenDay: nil, updatedAt: .now)
        #expect(unstamped.belongs(to: "acct-b"))
    }
}
