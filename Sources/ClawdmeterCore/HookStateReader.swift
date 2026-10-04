import Foundation

/// The latest hook event seen for a session, written by `clawdmeter hook`.
public struct HookRecord: Codable, Equatable, Sendable {
    public let sessionId: String
    public let event: String
    public let tool: String?
    public let cwd: String?
    public let pid: Int32?
    public let at: Date

    public init(sessionId: String, event: String, tool: String?, cwd: String?, pid: Int32?, at: Date) {
        self.sessionId = sessionId
        self.event = event
        self.tool = tool
        self.cwd = cwd
        self.pid = pid
        self.at = at
    }

    enum CodingKeys: String, CodingKey {
        case sessionId, event, tool, cwd, pid, at = "ts"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        event = try c.decode(String.self, forKey: .event)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
        at = dateFromEpoch(try c.decode(Double.self, forKey: .at))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(event, forKey: .event)
        try c.encodeIfPresent(tool, forKey: .tool)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(pid, forKey: .pid)
        try c.encode(at.timeIntervalSince1970, forKey: .at)
    }

    public var state: SessionState {
        switch event {
        case "PermissionRequest": .waiting
        case "UserPromptSubmit", "PreToolUse", "PostToolUse": .working
        default: .idle
        }
    }
}

public enum HookStateReader {
    static let maxAge: TimeInterval = 86_400

    public static func read(_ paths: ClaudePaths, now: Date = .now) -> [HookRecord] {
        let fm = FileManager.default
        return jsonFiles(in: paths.hooksDir).compactMap { url in
            if let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
               now.timeIntervalSince(modified) > maxAge {
                try? fm.removeItem(at: url)
                return nil
            }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(HookRecord.self, from: data)
        }
    }
}
