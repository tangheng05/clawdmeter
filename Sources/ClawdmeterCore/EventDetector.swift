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

    /// `fired` remembers alerts per window (keyed by reset time) so they never repeat.
    public static func limitEvents(old: RateLimits?, new: RateLimits?, fired: inout Set<String>) -> [AppEvent] {
        var events: [AppEvent] = []
        let pairs: [(String, LimitWindow?, LimitWindow?)] = [
            ("5-hour", old?.fiveHour, new?.fiveHour),
            ("Weekly", old?.sevenDay, new?.sevenDay),
        ]
        for (label, before, after) in pairs {
            guard let after else { continue }
            // Keyed by the reset hour, so small drifts in the reported reset time don't re-alert.
            let window = Int(((after.resetsAt?.timeIntervalSince1970 ?? 0) / 3600).rounded())
            if let crossed = thresholds.first(where: { after.usedPercentage >= Double($0) }) {
                let key = "\(label)-\(crossed)-\(window)"
                if !fired.contains(key) {
                    events.append(.limitCrossed(label: label, threshold: crossed))
                    for t in thresholds where Double(t) <= after.usedPercentage {
                        fired.insert("\(label)-\(t)-\(window)")
                    }
                }
            }
            if let before, before.usedPercentage >= 80, after.usedPercentage < before.usedPercentage,
               let oldReset = before.resetsAt, let newReset = after.resetsAt, newReset > oldReset.addingTimeInterval(60) {
                events.append(.limitReset(label: label))
            }
        }
        return events
    }

    /// Whether an alert key can still match, i.e. its window hasn't reset yet.
    public static func isLive(alertKey: String, now: Date = .now) -> Bool {
        guard let value = alertKey.split(separator: "-").last.flatMap({ Double($0) }) else { return false }
        // Older versions stored the reset time in seconds rather than hours.
        let resetsAt = value > 100_000_000 ? value : value * 3600
        return value == 0 || resetsAt > now.timeIntervalSince1970 - 3600
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
