import Foundation

public enum Keyframes {
    /// Start time of each frame as a fraction of the whole, plus the closing 1 that
    /// Core Animation needs for a discrete animation, or it plays nothing at all.
    public static func discreteTimes(_ durations: [TimeInterval]) -> [Double] {
        let total = durations.reduce(0, +)
        guard total > 0 else { return [] }
        var start = 0.0
        return durations.map { duration in
            defer { start += duration }
            return start / total
        } + [1]
    }
}
