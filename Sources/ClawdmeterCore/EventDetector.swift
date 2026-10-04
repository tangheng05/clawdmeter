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
            let window = Int(after.resetsAt?.timeIntervalSince1970 ?? 0)
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
}
