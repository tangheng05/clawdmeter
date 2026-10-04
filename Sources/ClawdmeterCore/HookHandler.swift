import Foundation

public enum HookHandler {
    public static func handle(event: String, input: Data, paths: ClaudePaths, parentPID: Int32, now: Date = .now) {
        guard let json = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let rawId = json["session_id"] as? String, let id = sanitizedSessionId(rawId) else { return }

        let file = paths.hooksDir.appending(path: "\(id).json")
        if event == "SessionEnd" {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let record = HookRecord(sessionId: id, event: event, tool: json["tool_name"] as? String,
                                cwd: json["cwd"] as? String, pid: parentPID, at: now)
        if let data = try? JSONEncoder().encode(record) {
            try? writeAtomically(data, to: file)
        }
    }
}
