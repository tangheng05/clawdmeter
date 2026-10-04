import Foundation

public enum SessionMerger {
    /// Native records are authoritative for state; hooks add the running tool and fill gaps.
    /// `isAlive` also gets a time the process must have existed by, to catch reused PIDs.
    /// `context` comes from the status line; `transcript` is the fallback for sessions without one (e.g. VS Code).
    public static func merge(native: [NativeSessionRecord], hooks: [HookRecord], context: [String: Double] = [:],
                             transcript: (String) -> TranscriptContext? = { _ in nil },
                             isAlive: (Int32, Date?) -> Bool) -> [Session] {
        let hooksById = Dictionary(hooks.map { ($0.sessionId, $0) }, uniquingKeysWith: { $0.at > $1.at ? $0 : $1 })
        var joined = Set<String>()
        var sessions: [Session] = []

        for record in native where isAlive(record.pid, record.statusChangedAt) {
            let id = record.sessionId ?? "pid-\(record.pid)"
            let hook = hooksById[id]
            joined.insert(id)
            let state = record.state ?? hook?.state ?? .idle
            let since = record.state == nil ? (hook?.at ?? record.statusChangedAt) : record.statusChangedAt
            sessions.append(Session(
                id: id, pid: record.pid, cwd: record.cwd ?? hook?.cwd ?? "", name: record.name,
                state: state, since: since ?? .now,
                tool: state == .working ? runningTool(hook) : nil,
                waitingFor: state == .waiting ? record.waitingFor : nil
            ))
        }

        for hook in hooksById.values where !joined.contains(hook.sessionId) {
            guard let pid = hook.pid, isAlive(pid, hook.at) else { continue }
            sessions.append(Session(
                id: hook.sessionId, pid: pid, cwd: hook.cwd ?? "", name: nil, state: hook.state, since: hook.at,
                tool: hook.state == .working ? runningTool(hook) : nil
            ))
        }

        for i in sessions.indices {
            if !sessions[i].cwd.isEmpty { sessions[i].branch = GitBranch.current(in: sessions[i].cwd) }
            if let used = context[sessions[i].sessionId] {
                sessions[i].contextUsed = used
            } else if let fallback = transcript(sessions[i].sessionId) {
                sessions[i].contextUsed = fallback.percent
                sessions[i].contextTokens = fallback.tokens
            }
            // Compaction runs between PreCompact and the next hook event.
            sessions[i].compacting = sessions[i].state == .working
                && hooksById[sessions[i].sessionId]?.event == "PreCompact"
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
