import Foundation

public enum StatuslineHandler {
    /// Saves `rate_limits` for the app, then returns the line Claude Code should display.
    public static func handle(input: Data, paths: ClaudePaths, now: Date = .now,
                              runPrevious: (String, Data) -> String?) -> String {
        let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]

        if let limits = json?["rate_limits"] as? [String: Any] {
            let account = Account.current(paths)
            if needsWrite(limits, account: account, paths: paths, now: now) {
                var saved: [String: Any] = ["ts": now.timeIntervalSince1970, "rate_limits": limits]
                saved["account"] = account
                if let data = try? JSONSerialization.data(withJSONObject: saved) {
                    try? writeAtomically(data, to: paths.limitsFile)
                }
            }
        }

        if let rawId = json?["session_id"] as? String, let id = sanitizedSessionId(rawId),
           let used = ((json?["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue {
            recordContext(used, sessionId: id, paths: paths)
        }
        if let model = (json?["model"] as? [String: Any])?["id"] as? String,
           let size = ((json?["context_window"] as? [String: Any])?["context_window_size"] as? NSNumber)?.intValue {
            ContextWindows.record(model: model, size: size, paths: paths)
        }

        if let previous = try? String(contentsOf: paths.previousStatuslineFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !previous.isEmpty {
            return runPrevious(previous, input) ?? ""
        }
        guard let json else { return "" }
        return compactLine(json)
    }

    /// One small file per session, rewritten only when the percentage changes.
    static func recordContext(_ used: Double, sessionId: String, paths: ClaudePaths) {
        let file = paths.contextDir.appending(path: "\(sessionId).json")
        if let data = try? Data(contentsOf: file),
           let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           (saved["used"] as? NSNumber)?.doubleValue == used { return }
        if let data = try? JSONSerialization.data(withJSONObject: ["used": used]) {
            try? writeAtomically(data, to: file)
        }
    }

    /// Skips rewriting identical limits for a minute; each write wakes the menu bar app.
    static func needsWrite(_ limits: [String: Any], account: String?, paths: ClaudePaths, now: Date) -> Bool {
        guard let data = try? Data(contentsOf: paths.limitsFile),
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ts = saved["ts"] as? Double,
              let savedLimits = saved["rate_limits"] as? [String: Any] else { return true }
        return now.timeIntervalSince1970 - ts >= 60 || saved["account"] as? String != account
            || !NSDictionary(dictionary: savedLimits).isEqual(to: limits)
    }

    static func compactLine(_ json: [String: Any]) -> String {
        var parts: [String] = []
        if let model = (json["model"] as? [String: Any])?["display_name"] as? String { parts.append(model) }
        let dir = ((json["workspace"] as? [String: Any])?["current_dir"] as? String) ?? json["cwd"] as? String
        if let dir { parts.append(URL(fileURLWithPath: dir).lastPathComponent) }
        let limits = json["rate_limits"] as? [String: Any]
        for (key, label) in [("five_hour", "5h"), ("seven_day", "wk")] {
            if let used = (limits?[key] as? [String: Any])?["used_percentage"] as? Double {
                parts.append("\(label) \(Int(used.rounded(.down)))%")
            }
        }
        return parts.joined(separator: " · ")
    }
}
