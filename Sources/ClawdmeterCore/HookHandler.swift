import Foundation

public enum HookHandler {
    public static func handle(event: String, input: Data, paths: ClaudePaths, parentPID: Int32, now: Date = .now) {
        guard let json = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let rawId = json["session_id"] as? String else { return }
        let id = String(rawId.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
            .prefix(64).map(Character.init))
        guard !id.isEmpty else { return }

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
