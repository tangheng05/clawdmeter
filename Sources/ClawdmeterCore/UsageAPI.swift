import Foundation

/// Asks Anthropic for the limits directly, so usage from VS Code, claude.ai or other devices shows up
/// even when no terminal session is running the status line.
public enum UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public enum Result: Equatable, Sendable {
        case limits(RateLimits)
        /// The login was refused, so it needs signing in again.
        case signedOut
        case unavailable
    }

    public static func fetch(paths: ClaudePaths, account: String?, now: Date = .now) async -> Result {
        guard let token = accessToken(paths: paths, now: now) else { return .unavailable }
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .unavailable }
        return result(status: status, data: data, account: account, now: now)
    }

    static func result(status: Int, data: Data, account: String?, now: Date) -> Result {
        if status == 401 { return .signedOut }
        guard status == 200, let limits = parse(data, account: account, now: now) else { return .unavailable }
        return .limits(limits)
    }

    static func parse(_ data: Data, account: String?, now: Date) -> RateLimits? {
        guard let usage = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return Account.usageLimits(usage, fetchedAt: now, account: account)
    }

    /// Never refreshes an expired token: that would rotate Claude Code's login and sign it out.
    static func accessToken(paths: ClaudePaths, now: Date) -> String? {
        guard paths.isDefault, let data = keychainCredentials() else { return nil }
        return token(fromCredentials: data, now: now)
    }

    static func token(fromCredentials data: Data, now: Date) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        if let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue, dateFromEpoch(expires) <= now { return nil }
        return token
    }

    /// Through `security`, which Claude Code's Keychain item already trusts, so there's no prompt.
    private static func keychainCredentials() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
