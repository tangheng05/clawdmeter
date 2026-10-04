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
        #expect(events == [.finished(sessionId: "a@1", name: "a", duration: 100)])
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
        #expect(events == [.needsYou(sessionId: "a@1", name: "a")])
    }

    @Test func newSessionAlreadyWaiting() {
        let events = EventDetector.sessionEvents(old: [], new: [session("a", .waiting, since: 10_000)], now: now)
        #expect(events == [.needsYou(sessionId: "a@1", name: "a")])
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
        let first = EventDetector.limitEvents(new: limits(five: 10, week: 81), now: now, fired: &fired)
        #expect(first == [.limitCrossed(label: "Weekly", threshold: 80)])
        let again = EventDetector.limitEvents(new: limits(five: 10, week: 82), now: now, fired: &fired)
        #expect(again.isEmpty)
    }

    @Test func jumpingPastBothThresholdsFiresHighestOnly() {
        var fired = Set<String>()
        let events = EventDetector.limitEvents(new: limits(five: 96, week: 10), now: now, fired: &fired)
        #expect(events == [.limitCrossed(label: "5-hour", threshold: 95)])
        #expect(EventDetector.limitEvents(new: limits(five: 97, week: 10), now: now, fired: &fired).isEmpty)
    }

    @Test func newWindowCanFireAgain() {
        var fired = Set<String>()
        _ = EventDetector.limitEvents(new: limits(five: 85, week: 10), now: now, fired: &fired)
        let events = EventDetector.limitEvents(new: limits(five: 85, week: 10, reset: 70_000), now: now, fired: &fired)
        #expect(events == [.limitCrossed(label: "5-hour", threshold: 80)])
    }

    @Test func expiredWindowAnnouncesResetOnceAndNeverRealerts() {
        var fired = Set<String>()
        let expired = limits(five: 92, week: 10, reset: 5_000)
        #expect(EventDetector.limitEvents(new: expired, now: now, fired: &fired) == [.limitReset(label: "5-hour")])
        #expect(EventDetector.limitEvents(new: expired, now: now, fired: &fired).isEmpty)
        var lowUse = Set<String>()
        #expect(EventDetector.limitEvents(new: limits(five: 30, week: 10, reset: 5_000), now: now, fired: &lowUse).isEmpty)
    }

    @Test func windowWithoutResetTimeNeverAlerts() {
        var fired = Set<String>()
        let limits = RateLimits(fiveHour: LimitWindow(usedPercentage: 90, resetsAt: nil), sevenDay: nil, updatedAt: now)
        #expect(EventDetector.limitEvents(new: limits, now: now, fired: &fired).isEmpty)
    }

    @Test func alertKeysLiveUntilAWeekAfterReset() {
        let reset = 36_000.0
        let key = "5-hour-80-\(Int(reset / 3600))"
        #expect(EventDetector.isLive(alertKey: key, now: Date(timeIntervalSince1970: reset + 86_400)))
        #expect(!EventDetector.isLive(alertKey: key, now: Date(timeIntervalSince1970: reset + 9 * 86_400)))
        #expect(!EventDetector.isLive(alertKey: "5-hour-80-0", now: now))
    }

    @Test func expiredWindowsReadAsZero() {
        let current = limits(five: 92, week: 40, reset: 5_000).current(now: now)
        #expect(current.fiveHour?.usedPercentage == 0)
        #expect(current.fiveHour?.resetsAt == nil)
        #expect(current.sevenDay?.usedPercentage == 40)
        #expect(current.headline?.label == "wk")
    }
}
