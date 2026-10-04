import Foundation
import Testing
@testable import ClawdmeterCore

@Suite struct EventDetectorTests {
    let now = Date(timeIntervalSince1970: 10_000)

    func session(_ id: String, _ state: SessionState, since: TimeInterval) -> Session {
        Session(id: id, pid: 1, cwd: "/w/\(id)", name: nil, state: state, since: Date(timeIntervalSince1970: since))
    }

    @Test func longTurnFinishing() {
        let events = EventDetector.sessionEvents(old: [session("a", .working, since: 9_900)],
                                                 new: [session("a", .idle, since: 10_000)], now: now)
        #expect(events == [.finished(sessionId: "a", name: "a", duration: 100)])
    }

    @Test func shortTurnIsQuiet() {
        let events = EventDetector.sessionEvents(old: [session("a", .working, since: 9_980)],
                                                 new: [session("a", .idle, since: 10_000)], now: now)
        #expect(events.isEmpty)
    }

    @Test func startingToWait() {
        let events = EventDetector.sessionEvents(old: [session("a", .working, since: 9_990), session("b", .waiting, since: 9_000)],
                                                 new: [session("a", .waiting, since: 10_000), session("b", .waiting, since: 9_000)],
                                                 now: now)
        #expect(events == [.needsYou(sessionId: "a", name: "a")])
    }

    @Test func newSessionAlreadyWaiting() {
        let events = EventDetector.sessionEvents(old: [], new: [session("a", .waiting, since: 10_000)], now: now)
        #expect(events == [.needsYou(sessionId: "a", name: "a")])
    }

    @Test func identicalReloadIsQuiet() {
        let s = [session("a", .idle, since: 1), session("b", .waiting, since: 2)]
        #expect(EventDetector.sessionEvents(old: s, new: s, now: now).isEmpty)
    }

    func limits(five: Double, week: Double, reset: TimeInterval = 50_000) -> RateLimits {
        RateLimits(fiveHour: LimitWindow(usedPercentage: five, resetsAt: Date(timeIntervalSince1970: reset)),
                   sevenDay: LimitWindow(usedPercentage: week, resetsAt: Date(timeIntervalSince1970: 900_000)),
                   updatedAt: now)
    }

    @Test func thresholdFiresOncePerWindow() {
        var fired = Set<String>()
        let first = EventDetector.limitEvents(old: limits(five: 10, week: 79), new: limits(five: 10, week: 81), fired: &fired)
        #expect(first == [.limitCrossed(label: "Weekly", threshold: 80)])
        let again = EventDetector.limitEvents(old: limits(five: 10, week: 81), new: limits(five: 10, week: 82), fired: &fired)
        #expect(again.isEmpty)
    }

    @Test func jumpingPastBothThresholdsFiresHighestOnly() {
        var fired = Set<String>()
        let events = EventDetector.limitEvents(old: nil, new: limits(five: 96, week: 10), fired: &fired)
        #expect(events == [.limitCrossed(label: "5-hour", threshold: 95)])
        #expect(EventDetector.limitEvents(old: nil, new: limits(five: 97, week: 10), fired: &fired).isEmpty)
    }

    @Test func newWindowCanFireAgain() {
        var fired = Set<String>()
        _ = EventDetector.limitEvents(old: nil, new: limits(five: 85, week: 10), fired: &fired)
        let events = EventDetector.limitEvents(old: nil, new: limits(five: 85, week: 10, reset: 70_000), fired: &fired)
        #expect(events == [.limitCrossed(label: "5-hour", threshold: 80)])
    }

    @Test func resetAfterHeavyUseIsAnnounced() {
        var fired = Set<String>()
        let events = EventDetector.limitEvents(old: limits(five: 92, week: 10), new: limits(five: 0, week: 10, reset: 68_000),
                                               fired: &fired)
        #expect(events.contains(.limitReset(label: "5-hour")))
        let quiet = EventDetector.limitEvents(old: limits(five: 30, week: 10), new: limits(five: 0, week: 10, reset: 68_000),
                                              fired: &fired)
        #expect(!quiet.contains(.limitReset(label: "5-hour")))
    }
}
