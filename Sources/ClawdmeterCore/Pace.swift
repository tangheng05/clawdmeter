import Foundation

public enum PaceForecast: Equatable, Sendable {
    case hitsLimit(at: Date)
    case onTrack(projected: Int)
}

public enum Pace {
    /// Linear projection from the start of the window; hidden until there is enough signal.
    public static func forecast(_ window: LimitWindow, period: TimeInterval = 7 * 86_400,
                                now: Date = .now) -> PaceForecast? {
        guard let reset = window.resetsAt, reset > now, window.usedPercentage >= 5, window.usedPercentage < 100
        else { return nil }
        let start = reset.addingTimeInterval(-period)
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= 6 * 3600 else { return nil }
        let projected = window.usedPercentage * period / elapsed
        if projected >= 100 {
            return .hitsLimit(at: start.addingTimeInterval(elapsed * 100 / window.usedPercentage))
        }
        return .onTrack(projected: Int(projected.rounded()))
    }
}

public struct UsageHistory: Sendable {
    public struct Sample: Codable, Equatable, Sendable {
        public let ts: Double
        public let week: Double

        public init(ts: Double, week: Double) {
            self.ts = ts
            self.week = week
        }
    }

    public struct Day: Equatable, Sendable {
        public let date: Date
        public let amount: Double
    }

    static let keep: TimeInterval = 8 * 86_400
    let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func load() -> [Sample] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Sample].self, from: data)) ?? []
    }

    public func record(_ limits: RateLimits, now: Date = .now) {
        guard let week = limits.sevenDay?.usedPercentage else { return }
        var samples = load().filter { now.timeIntervalSince1970 - $0.ts < Self.keep }
        if samples.last?.week == week { return }
        samples.append(Sample(ts: now.timeIntervalSince1970, week: week))
        if let data = try? JSONEncoder().encode(samples) {
            try? writeAtomically(data, to: file)
        }
    }

    /// Weekly-limit percentage used per calendar day; a drop means the window reset.
    public static func dailyUsage(_ samples: [Sample], days: Int, now: Date = .now,
                                  calendar: Calendar = .current) -> [Day] {
        let today = calendar.startOfDay(for: now)
        var totals: [Date: Double] = [:]
        for (before, after) in zip(samples, samples.dropFirst()) {
            let delta = after.week >= before.week ? after.week - before.week : after.week
            totals[calendar.startOfDay(for: Date(timeIntervalSince1970: after.ts)), default: 0] += delta
        }
        return (0..<days).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { Day(date: $0, amount: totals[$0] ?? 0) }
        }
    }
}
