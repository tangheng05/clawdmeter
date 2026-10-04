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
    }

    public static func read(_ paths: ClaudePaths) -> RateLimits? {
        guard let data = try? Data(contentsOf: paths.limitsFile),
              let raw = try? JSONDecoder().decode(Raw.self, from: data),
              let limits = raw.rate_limits else { return nil }
        let five = window(limits.five_hour)
        let seven = window(limits.seven_day)
        if five == nil, seven == nil { return nil }
        return RateLimits(fiveHour: five, sevenDay: seven, updatedAt: dateFromEpoch(raw.ts))
    }

    private static func window(_ w: Raw.Window?) -> LimitWindow? {
        guard let used = w?.used_percentage else { return nil }
        return LimitWindow(usedPercentage: used, resetsAt: w?.resets_at.map(dateFromEpoch))
    }
}
