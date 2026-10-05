import Testing
@testable import ClawdmeterCore

@Suite struct KeyframesTests {
    @Test func discreteKeyTimesHaveOneMoreEntryThanFrames() {
        // Core Animation ignores a discrete animation whose keyTimes don't end at 1.
        #expect(Keyframes.discreteTimes([1, 1]) == [0, 0.5, 1])
        #expect(Keyframes.discreteTimes([3, 1]) == [0, 0.75, 1])
    }
}
