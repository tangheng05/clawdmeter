import Foundation

public enum StatuslineHandler {
    /// Saves `rate_limits` for the app, then returns the line Claude Code should display.
    public static func handle(input: Data, paths: ClaudePaths, now: Date = .now,
                              runPrevious: (String, Data) -> String?) -> String {
        let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]

        if let limits = json?["rate_limits"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: ["ts": now.timeIntervalSince1970, "rate_limits": limits]) {
            try? writeAtomically(data, to: paths.limitsFile)
        }

        if let previous = try? String(contentsOf: paths.previousStatuslineFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !previous.isEmpty {
            return runPrevious(previous, input) ?? ""
        }
        guard let json else { return "" }
        return compactLine(json)
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
