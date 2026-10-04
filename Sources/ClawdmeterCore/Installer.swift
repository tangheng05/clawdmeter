import Foundation

public enum InstallerError: Error, LocalizedError {
    case unreadableSettings(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableSettings(let reason): "Couldn't read ~/.claude/settings.json: \(reason)"
        }
    }
}

public struct InstallStatus: Equatable, Sendable {
    public let statusline: Bool
    public let hooks: Bool
    public let nativeSessions: Bool

    public init(statusline: Bool, hooks: Bool, nativeSessions: Bool) {
        self.statusline = statusline
        self.hooks = hooks
        self.nativeSessions = nativeSessions
    }
}

public struct Installer: Sendable {
    public static let hookEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                                    "PermissionRequest", "Stop", "SessionEnd"]

    let paths: ClaudePaths
    let helperSource: URL

    public init(paths: ClaudePaths, helperSource: URL) {
        self.paths = paths
        self.helperSource = helperSource
    }

    private var helperCommand: String { "\"\(paths.helperPath.path)\"" }

    private func isOurs(_ command: Any?) -> Bool {
        (command as? String)?.contains(paths.helperPath.path) == true
    }

    public func install() throws {
        var settings = try readSettings()
        try installHelper()
        try backup()

        var line = settings["statusLine"] as? [String: Any] ?? [:]
        if let existing = line["command"] as? String, !existing.isEmpty, !isOurs(existing) {
            try writeAtomically(Data(existing.utf8), to: paths.previousStatuslineFile)
        }
        line["type"] = "command"
        line["command"] = "\(helperCommand) statusline"
        settings["statusLine"] = line

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in Self.hookEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let present = groups.contains { ($0["hooks"] as? [[String: Any]] ?? []).contains { isOurs($0["command"]) } }
            if !present {
                groups.append(["hooks": [["type": "command", "command": "\(helperCommand) hook \(event)", "timeout": 5]]])
            }
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try writeSettings(settings)
    }

    /// Updates the copied helper after an app update; does nothing if the integration isn't installed.
    @discardableResult
    public func refreshHelperIfNeeded() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.helperPath.path),
              let bundled = try? Data(contentsOf: helperSource),
              (try? Data(contentsOf: paths.helperPath)) != bundled else { return false }
        return (try? installHelper()) != nil
    }

    public func uninstall() throws {
        var settings = try readSettings()
        try backup()

        if var line = settings["statusLine"] as? [String: Any], isOurs(line["command"]) {
            let previous = (try? String(contentsOf: paths.previousStatuslineFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let previous, !previous.isEmpty {
                line["command"] = previous
                settings["statusLine"] = line
            } else {
                settings["statusLine"] = nil
            }
        }

        if var hooks = settings["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else { continue }
                let kept: [[String: Any]] = groups.compactMap { group in
                    guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                    let remaining = entries.filter { !isOurs($0["command"]) }
                    if remaining.isEmpty { return nil }
                    var copy = group
                    copy["hooks"] = remaining
                    return copy
                }
                hooks[event] = kept.isEmpty ? nil : kept
            }
            settings["hooks"] = hooks.isEmpty ? nil : hooks
        }

        try writeSettings(settings)
        try? FileManager.default.removeItem(at: paths.appDir)
    }

    public func status() -> InstallStatus {
        let settings = (try? readSettings()) ?? [:]
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let hooksInstalled = Self.hookEvents.allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains {
                ($0["hooks"] as? [[String: Any]] ?? []).contains { isOurs($0["command"]) }
            }
        }
        return InstallStatus(
            statusline: isOurs((settings["statusLine"] as? [String: Any])?["command"]),
            hooks: hooksInstalled && FileManager.default.isExecutableFile(atPath: paths.helperPath.path),
            nativeSessions: FileManager.default.fileExists(atPath: paths.sessionsDir.path)
        )
    }

    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: paths.settingsFile.path) else { return [:] }
        do {
            let data = try Data(contentsOf: paths.settingsFile)
            if data.isEmpty { return [:] }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallerError.unreadableSettings("top level is not an object")
            }
            return object
        } catch let error as InstallerError {
            throw error
        } catch {
            throw InstallerError.unreadableSettings(error.localizedDescription)
        }
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try writeAtomically(data, to: paths.settingsFile)
    }

    private func installHelper() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.binDir, withIntermediateDirectories: true)
        let temp = paths.binDir.appending(path: ".clawdmeter-\(UUID().uuidString)")
        try fm.copyItem(at: helperSource, to: temp)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
        _ = try fm.replaceItemAt(paths.helperPath, withItemAt: temp)
    }

    private func backup() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.settingsFile.path) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let target = paths.claudeDir.appending(path: "settings.json.clawdmeter-backup-\(formatter.string(from: .now))")
        try? fm.removeItem(at: target)
        try fm.copyItem(at: paths.settingsFile, to: target)
    }
}
