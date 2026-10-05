import Foundation

public enum LimitsReader {
    private struct Raw: Decodable {
        struct Window: Decodable {
            let used_percentage: Double?
            let resets_at: Double?
        }
        struct Limits: Decodable {
            let five_hour: Window?
            let seven_day: Window?
        }
        let ts: Double
        let rate_limits: Limits?
        let account: String?
    }

    public static func read(_ paths: ClaudePaths) -> RateLimits? {
        guard let data = try? Data(contentsOf: paths.limitsFile),
              let raw = try? JSONDecoder().decode(Raw.self, from: data),
              let limits = raw.rate_limits else { return nil }
        let five = window(limits.five_hour)
        let seven = window(limits.seven_day)
        if five == nil, seven == nil { return nil }
        return RateLimits(fiveHour: five, sevenDay: seven, updatedAt: dateFromEpoch(raw.ts), account: raw.account)
    }

    private static func window(_ w: Raw.Window?) -> LimitWindow? {
        guard let used = w?.used_percentage else { return nil }
        return LimitWindow(usedPercentage: used, resetsAt: w?.resets_at.map(dateFromEpoch))
    }
}

extension RateLimits {
    /// Status line data or Claude Code's own usage cache, whichever is newer. After switching
    /// accounts, the old account's limits wait until the new one reports its own.
    public static func best(_ status: RateLimits?, cached: RateLimits?, account: String?) -> RateLimits? {
        [status, cached].compactMap { $0 }.filter { $0.belongs(to: account) }.reduce(nil, newest)
    }

    public static func best(paths: ClaudePaths) -> RateLimits? {
        let snapshot = Account.read(paths)
        return best(LimitsReader.read(paths), cached: snapshot.cachedLimits, account: snapshot.account)
    }
}

/// The limits as `clawdmeter limits` prints them, for scripts and agents.
public struct LimitsReport: Encodable, Sendable {
    public struct Window: Encodable, Sendable {
        let usedPercent: Double
        let leftPercent: Double
        let resetsAt: Date?
    }

    let account: String?
    let plan: String?
    let fiveHour: Window?
    let sevenDay: Window?
    let updatedAt: Date?
    let stale: Bool

    public init(limits: RateLimits?, snapshot: AccountSnapshot, now: Date = .now) {
        let current = limits?.current(now: now)
        func window(_ w: LimitWindow?) -> Window? {
            w.map { Window(usedPercent: $0.usedPercentage, leftPercent: max(0, 100 - $0.usedPercentage), resetsAt: $0.resetsAt) }
        }
        account = snapshot.account
        plan = snapshot.plan
        fiveHour = window(current?.fiveHour)
        sevenDay = window(current?.sevenDay)
        updatedAt = limits?.updatedAt
        stale = limits?.isStale(now: now) ?? true
    }
}
