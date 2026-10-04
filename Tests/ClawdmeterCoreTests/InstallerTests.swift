import Foundation
import Testing
@testable import ClawdmeterCore

@Suite struct InstallerTests {
    let dir: TempDir
    let installer: Installer

    init() throws {
        dir = try TempDir()
        try dir.write("#!/bin/sh\n", to: "helper-src")
        installer = Installer(paths: dir.paths, helperSource: dir.url.appending(path: "helper-src"))
    }

    func settings() throws -> [String: Any] {
        let data = try Data(contentsOf: dir.paths.settingsFile)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func commands(_ s: [String: Any], _ event: String) -> [String] {
        let groups = (s["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    var statusCommand: String { "\"\(dir.paths.helperPath.path)\" statusline" }

    @Test func freshInstall() throws {
        try installer.install()
        let s = try settings()
        #expect((s["statusLine"] as? [String: Any])?["command"] as? String == statusCommand)
        for event in Installer.hookEvents {
            #expect(commands(s, event) == ["\"\(dir.paths.helperPath.path)\" hook \(event)"])
        }
        #expect(FileManager.default.isExecutableFile(atPath: dir.paths.helperPath.path))
        #expect(installer.status().statusline && installer.status().hooks)
    }

    @Test func wrapsExistingStatuslineAndKeepsOtherSettings() throws {
        try dir.write(#"{"theme":"dark","statusLine":{"type":"command","command":"mine.sh","padding":2}}"#,
                      to: "settings.json")
        try installer.install()
        let s = try settings()
        #expect(s["theme"] as? String == "dark")
        let line = try #require(s["statusLine"] as? [String: Any])
        #expect(line["command"] as? String == statusCommand)
        #expect(line["padding"] as? Int == 2)
        #expect(try String(contentsOf: dir.paths.previousStatuslineFile, encoding: .utf8) == "mine.sh")
    }

    @Test func preservesForeignHooksAndIsIdempotent() throws {
        try dir.write(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#,
                      to: "settings.json")
        try installer.install()
        try installer.install()
        let s = try settings()
        #expect(commands(s, "Stop") == ["say done", "\"\(dir.paths.helperPath.path)\" hook Stop"])
        #expect(commands(s, "PreToolUse").count == 1)
        #expect(!FileManager.default.fileExists(atPath: dir.paths.previousStatuslineFile.path))
    }

    @Test func uninstallRestoresOriginal() throws {
        try dir.write("""
        {"statusLine":{"type":"command","command":"mine.sh"},
         "hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}
        """, to: "settings.json")
        try installer.install()
        try installer.uninstall()
        let s = try settings()
        #expect((s["statusLine"] as? [String: Any])?["command"] as? String == "mine.sh")
        #expect(commands(s, "Stop") == ["say done"])
        #expect((s["hooks"] as? [String: Any])?.keys.sorted() == ["Stop"])
        #expect(!FileManager.default.fileExists(atPath: dir.paths.appDir.path))
        #expect(!installer.status().statusline && !installer.status().hooks)
    }

    @Test func uninstallFromFreshRemovesEverything() throws {
        try installer.install()
        try installer.uninstall()
        let s = try settings()
        #expect(s["statusLine"] == nil)
        #expect(s["hooks"] == nil)
    }

    @Test func refusesCorruptSettings() throws {
        try dir.write("{ not json", to: "settings.json")
        #expect(throws: InstallerError.self) { try installer.install() }
        #expect(try String(contentsOf: dir.paths.settingsFile, encoding: .utf8) == "{ not json")
        #expect(!FileManager.default.fileExists(atPath: dir.paths.helperPath.path))
    }

    @Test func backsUpExistingSettings() throws {
        try dir.write(#"{"theme":"dark"}"#, to: "settings.json")
        try installer.install()
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
            .filter { $0.hasPrefix("settings.json.clawdmeter-backup-") }
        #expect(backups.count == 1)
    }
}
