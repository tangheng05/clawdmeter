import Foundation

/// A session as described by Claude Code's own `~/.claude/sessions/<pid>.json`.
public struct NativeSessionRecord: Equatable, Sendable {
    public let pid: Int32
    public let sessionId: String?
    public let cwd: String?
    public let name: String?
    /// nil when the file carries no status we recognise.
    public let state: SessionState?
    public let waitingFor: String?
    public let statusChangedAt: Date?
}

public enum NativeSessionReader {
    private struct Raw: Decodable {
        let pid: Int32
        let sessionId: String?
        let cwd: String?
        let name: String?
        let status: String?
        let waitingFor: String?
        let statusUpdatedAt: Double?
        let updatedAt: Double?
    }

    public static func read(_ paths: ClaudePaths) -> [NativeSessionRecord] {
        jsonFiles(in: paths.sessionsDir).compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
            return NativeSessionRecord(
                pid: raw.pid,
                sessionId: raw.sessionId,
                cwd: raw.cwd,
                name: raw.name,
                state: state(status: raw.status, waitingFor: raw.waitingFor),
                waitingFor: raw.waitingFor,
                statusChangedAt: (raw.statusUpdatedAt ?? raw.updatedAt).map(dateFromEpoch)
            )
        }
    }

    static func state(status: String?, waitingFor: String?) -> SessionState? {
        if let waitingFor, !waitingFor.isEmpty { return .waiting }
        switch status {
        case "busy", "working", "running": return .working
        case "waiting", "needs_input", "requires_action": return .waiting
        case "idle": return .idle
        default: return nil
        }
    }
}

func jsonFiles(in dir: URL) -> [URL] {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }
}

/// Accepts epoch seconds or milliseconds.
func dateFromEpoch(_ value: Double) -> Date {
    Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
}
