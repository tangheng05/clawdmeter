import Foundation

public enum SessionMerger {
    /// Native records are authoritative for state; hooks add the running tool and fill gaps.
    public static func merge(native: [NativeSessionRecord], hooks: [HookRecord],
                             isAlive: (Int32) -> Bool) -> [Session] {
        var hooksById = Dictionary(hooks.map { ($0.sessionId, $0) }, uniquingKeysWith: { $0.at > $1.at ? $0 : $1 })
        var sessions: [Session] = []

        for record in native where isAlive(record.pid) {
            let id = record.sessionId ?? "pid-\(record.pid)"
            let hook = hooksById.removeValue(forKey: id)
            let state = record.state ?? hook?.state ?? .idle
            let since = record.state == nil ? (hook?.at ?? record.statusChangedAt) : record.statusChangedAt
            sessions.append(Session(
                id: id, pid: record.pid, cwd: record.cwd ?? hook?.cwd ?? "", name: record.name,
                state: state, since: since ?? .now,
                tool: state == .working ? runningTool(hook) : nil,
                waitingFor: state == .waiting ? record.waitingFor : nil
            ))
        }

        for hook in hooksById.values {
            guard let pid = hook.pid, isAlive(pid) else { continue }
            sessions.append(Session(
                id: hook.sessionId, pid: pid, cwd: hook.cwd ?? "", name: nil, state: hook.state, since: hook.at,
                tool: hook.state == .working ? runningTool(hook) : nil
            ))
        }

        return sessions.sorted { a, b in
            a.state != b.state ? a.state > b.state : a.since > b.since
        }
    }

    private static func runningTool(_ hook: HookRecord?) -> String? {
        hook?.event == "PreToolUse" ? hook?.tool : nil
    }
}

public struct Aggregate: Equatable, Sendable {
    public let state: SessionState
    public let count: Int

    public init(sessions: [Session]) {
        state = sessions.map(\.state).max() ?? .idle
        count = sessions.count
    }
}
