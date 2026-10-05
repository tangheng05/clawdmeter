import Foundation

public struct ClaudePaths: Sendable {
    public let claudeDir: URL

    public init(claudeDir: URL = ClaudePaths.defaultClaudeDir) {
        self.claudeDir = claudeDir
    }

    public static var defaultClaudeDir: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    }

    public var sessionsDir: URL { claudeDir.appending(path: "sessions") }
    public var settingsFile: URL { claudeDir.appending(path: "settings.json") }
    public var appDir: URL { claudeDir.appending(path: "clawdmeter") }
    public var hooksDir: URL { appDir.appending(path: "hooks") }
    public var limitsFile: URL { appDir.appending(path: "limits.json") }
    public var contextDir: URL { appDir.appending(path: "context") }
    public var windowsFile: URL { appDir.appending(path: "windows.json") }
    public var projectsDir: URL { claudeDir.appending(path: "projects") }
    public var binDir: URL { appDir.appending(path: "bin") }
    public var helperPath: URL { binDir.appending(path: "clawdmeter") }
    public var previousStatuslineFile: URL { appDir.appending(path: "previous-statusline") }

    /// Claude Code keeps the signed-in account next to the default config dir, or inside a custom one.
    public var accountFile: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return claudeDir.standardizedFileURL == home.appending(path: ".claude").standardizedFileURL
            ? home.appending(path: ".claude.json")
            : claudeDir.appending(path: ".claude.json")
    }
}

public struct AccountSnapshot: Equatable, Sendable {
    /// The signed-in Claude account, or nil when using an API key or signed out.
    public let account: String?
    /// Claude Code's own cached usage, shared by the terminal and the VS Code extension.
    public let cachedLimits: RateLimits?
    /// "Pro", "Max 5x" and so on, when Claude Code knows the subscription.
    public var plan: String? = nil
}

public enum Account {
    public static func current(_ paths: ClaudePaths) -> String? {
        read(paths).account
    }

    public static func read(_ paths: ClaudePaths) -> AccountSnapshot {
        guard let data = try? Data(contentsOf: paths.accountFile),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return AccountSnapshot(account: nil, cachedLimits: nil)
        }
        let oauth = json["oauthAccount"] as? [String: Any]
        return AccountSnapshot(account: oauth?["accountUuid"] as? String,
                               cachedLimits: cachedLimits(json["cachedUsageUtilization"]),
                               plan: oauth.flatMap(plan))
    }

    private static func plan(_ oauth: [String: Any]) -> String? {
        switch oauth["organizationType"] as? String {
        case "claude_pro": return "Pro"
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        case "claude_max":
            let tier = [oauth["organizationRateLimitTier"], oauth["userRateLimitTier"]].compactMap { $0 as? String }.joined()
            return tier.contains("20x") ? "Max 20x" : tier.contains("5x") ? "Max 5x" : "Max"
        default: return nil
        }
    }

    private static func cachedLimits(_ value: Any?) -> RateLimits? {
        guard let cache = value as? [String: Any],
              let fetched = (cache["fetchedAtMs"] as? NSNumber)?.doubleValue,
              let usage = cache["utilization"] as? [String: Any] else { return nil }
        func window(_ key: String) -> LimitWindow? {
            guard let entry = usage[key] as? [String: Any],
                  let used = (entry["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return LimitWindow(usedPercentage: used, resetsAt: (entry["resets_at"] as? String).flatMap(parseDate))
        }
        let five = window("five_hour"), seven = window("seven_day")
        guard five != nil || seven != nil else { return nil }
        return RateLimits(fiveHour: five, sevenDay: seven, updatedAt: dateFromEpoch(fetched),
                          account: cache["accountUuid"] as? String)
    }

    /// ISO 8601 with up to microseconds, e.g. "2026-10-04T15:59:59.664258+00:00".
    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        // Trim the fraction to milliseconds, which every Foundation version accepts.
        guard let dot = text.firstIndex(of: "."),
              let end = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) else {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }
        let fraction = text[text.index(after: dot)..<end]
        let trimmed = String(text[..<dot]) + "." + fraction.prefix(3) + text[end...]
        return formatter.date(from: trimmed)
    }
}

/// Session ids become file names, so keep only safe characters.
func sanitizedSessionId(_ raw: String) -> String? {
    let id = String(raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        .prefix(64).map(Character.init))
    return id.isEmpty ? nil : id
}

public func writeAtomically(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}
