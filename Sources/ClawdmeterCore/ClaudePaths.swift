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
    public var binDir: URL { appDir.appending(path: "bin") }
    public var helperPath: URL { binDir.appending(path: "clawdmeter") }
    public var previousStatuslineFile: URL { appDir.appending(path: "previous-statusline") }
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
