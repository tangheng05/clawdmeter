import Foundation

public enum AppEvent: Equatable, Sendable {
    case finished(sessionId: String, name: String, duration: TimeInterval)
    case needsYou(sessionId: String, name: String)
    case limitCrossed(label: String, threshold: Int)
    case limitReset(label: String)
}

public enum EventDetector {
    static let minTurn: TimeInterval = 30
    static let thresholds = [95, 80]

    public static func sessionEvents(old: [Session], new: [Session], now: Date = .now) -> [AppEvent] {
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var events: [AppEvent] = []
        for session in new {
            let before = previous[session.id]
            if session.state == .waiting, before?.state != .waiting {
                events.append(.needsYou(sessionId: session.id, name: session.displayName))
            } else if let before, before.state == .working, session.state == .idle {
                let duration = now.timeIntervalSince(before.since)
                if duration >= minTurn {
                    events.append(.finished(sessionId: session.id, name: session.displayName, duration: duration))
                }
            }
        }
        return events
    }

    /// `fired` remembers alerts per window (keyed by reset hour) so they never repeat, even
    /// when stale limits are re-read long after the window ended.
    public static func limitEvents(new: RateLimits?, now: Date = .now, fired: inout Set<String>) -> [AppEvent] {
        var events: [AppEvent] = []
        for (label, window) in [("5-hour", new?.fiveHour), ("Weekly", new?.sevenDay)] {
            guard let window, let reset = window.resetsAt else { continue }
            let hour = Int((reset.timeIntervalSince1970 / 3600).rounded())
            if reset <= now {
                let key = "\(label)-reset-\(hour)"
                if window.usedPercentage >= 80, !fired.contains(key) {
                    events.append(.limitReset(label: label))
                    fired.insert(key)
                }
                continue
            }
            if let crossed = thresholds.first(where: { window.usedPercentage >= Double($0) }),
               !fired.contains("\(label)-\(crossed)-\(hour)") {
                events.append(.limitCrossed(label: label, threshold: crossed))
                for t in thresholds where Double(t) <= window.usedPercentage {
                    fired.insert("\(label)-\(t)-\(hour)")
                }
            }
        }
        return events
    }

    /// Whether an alert key can still match, i.e. its window hasn't reset yet.
    public static func isLive(alertKey: String, now: Date = .now) -> Bool {
        guard let value = alertKey.split(separator: "-").last.flatMap({ Double($0) }), value > 0 else { return false }
        // Older versions stored the reset time in seconds rather than hours.
        let resetsAt = value > 100_000_000 ? value : value * 3600
        // Kept for a week past the reset, since stale limits can be re-read for days.
        return resetsAt > now.timeIntervalSince1970 - 8 * 86_400
    }

}

/// Last known state of each session, kept until its process exits, so a session that
/// vanishes for one read (e.g. a half-written file) doesn't produce duplicate events.
public struct SessionMemory: Sendable {
    private var known: [String: Session] = [:]

    public init() {}

    public mutating func advance(to sessions: [Session], isAlive: (Int32) -> Bool, now: Date = .now) -> [AppEvent] {
        let events = EventDetector.sessionEvents(old: Array(known.values), new: sessions, now: now)
        for session in sessions { known[session.id] = session }
        known = known.filter { isAlive($0.value.pid) }
        return events
    }
}

/// Limit alerts already sent, persisted so they don't repeat after a restart.
public struct AlertLog: @unchecked Sendable {
    static let key = "alertedLimits"
    let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    public func save(_ fired: Set<String>, now: Date = .now) {
        // UserDefaults only stores arrays, never sets.
        defaults.set(fired.filter { EventDetector.isLive(alertKey: $0, now: now) }.sorted(), forKey: Self.key)
    }
}
