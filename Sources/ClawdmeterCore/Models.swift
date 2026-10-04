import Foundation

public enum SessionState: Int, Comparable, Sendable {
    case idle, working, waiting

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct Session: Identifiable, Equatable, Sendable {
    public let id: String
    public let pid: Int32
    public let cwd: String
    public let name: String?
    public var state: SessionState
    public var since: Date
    public var tool: String?
    public var waitingFor: String?
    public var branch: String?

    public init(id: String, pid: Int32, cwd: String, name: String?, state: SessionState, since: Date,
                tool: String? = nil, waitingFor: String? = nil, branch: String? = nil) {
        self.id = id
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

    /// The window closest to its limit, for the menu bar.
    public var headline: (label: String, window: LimitWindow)? {
        let candidates = [("5h", fiveHour), ("wk", sevenDay)].compactMap { label, w in w.map { (label, $0) } }
        return candidates.max { $0.1.usedPercentage < $1.1.usedPercentage }.map { (label: $0.0, window: $0.1) }
    }
}
