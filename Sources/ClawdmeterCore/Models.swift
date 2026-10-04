import Foundation

public enum SessionState: Int, Comparable, Sendable {
    case idle, working, waiting

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct Session: Identifiable, Equatable, Sendable {
    /// Unique per process: two terminals can resume the same conversation.
    public let id: String
    public let sessionId: String
    public let pid: Int32
    public let cwd: String
    public let name: String?
    public var state: SessionState
    public var since: Date
    public var tool: String?
    public var waitingFor: String?
    public var branch: String?
    /// Percentage of the context window in use, when the status line has reported it.
    public var contextUsed: Double?
    /// Tokens in the context window, when only the conversation log is available.
    public var contextTokens: Int?
    /// Claude is compacting this session's context.
    public var compacting = false

    public init(id: String, pid: Int32, cwd: String, name: String?, state: SessionState, since: Date,
                tool: String? = nil, waitingFor: String? = nil, branch: String? = nil) {
        self.id = "\(id)@\(pid)"
        self.sessionId = id
        self.pid = pid
        self.cwd = cwd
        self.name = name
        self.state = state
        self.since = since
        self.tool = tool
        self.waitingFor = waitingFor
        self.branch = branch
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        return folder.isEmpty ? "Claude" : folder
    }
}

public struct LimitWindow: Equatable, Sendable {
    public let usedPercentage: Double
    public let resetsAt: Date?

    public init(usedPercentage: Double, resetsAt: Date?) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }
}

public struct RateLimits: Equatable, Sendable {
    public static let staleAfter: TimeInterval = 600

    public let fiveHour: LimitWindow?
    public let sevenDay: LimitWindow?
    public let updatedAt: Date

    public init(fiveHour: LimitWindow?, sevenDay: LimitWindow?, updatedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.updatedAt = updatedAt
    }

    public func isStale(now: Date = .now) -> Bool {
        now.timeIntervalSince(updatedAt) > Self.staleAfter
    }

    /// Windows whose reset time has passed read as 0%, since that usage no longer counts.
    public func current(now: Date = .now) -> RateLimits {
        func fresh(_ window: LimitWindow?) -> LimitWindow? {
            guard let window, let reset = window.resetsAt, reset <= now else { return window }
            return LimitWindow(usedPercentage: 0, resetsAt: nil)
        }
        return RateLimits(fiveHour: fresh(fiveHour), sevenDay: fresh(sevenDay), updatedAt: updatedAt)
    }

    /// The earliest reset still ahead, so the app can refresh right when it happens.
    public func nextReset(after now: Date = .now) -> Date? {
        [fiveHour?.resetsAt, sevenDay?.resetsAt].compactMap { $0 }.filter { $0 > now }.min()
    }

    /// The window closest to its limit, for the menu bar.
    public var headline: (label: String, window: LimitWindow)? {
        let candidates = [("5h", fiveHour), ("wk", sevenDay)].compactMap { label, w in w.map { (label, $0) } }
        return candidates.max { $0.1.usedPercentage < $1.1.usedPercentage }.map { (label: $0.0, window: $0.1) }
    }
}
