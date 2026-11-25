import Foundation
import Testing
@testable import ClawdmeterCore

final class MemorySecrets: SecretStore, @unchecked Sendable {
    var items: [String: Data] = [:]
    var writes = 0
    var failWrites = 0
    var afterWrite: ((String) -> Void)?

    func read(service: String, account: String) -> Data? { items["\(service)|\(account)"] }
    func write(_ data: Data, service: String, account: String) throws {
        if failWrites > 0 {
            failWrites -= 1
            throw SwitchError.writeFailed("test")
        }
        writes += 1
        items["\(service)|\(account)"] = data
        afterWrite?(service)
    }
    func delete(service: String, account: String) { items["\(service)|\(account)"] = nil }
}

@Suite struct AccountSwitcherTests {
    let dir: TempDir
    let secrets = MemorySecrets()
    let switcher: AccountSwitcher
    let mcp: [String: Any] = ["plugin:stripe": ["serverName": "stripe", "accessToken": ""]]

    init() throws {
        dir = try TempDir()
        switcher = AccountSwitcher(paths: dir.paths, secrets: secrets, user: "u", lockTimeout: 0.3)
    }

    func oauth(_ account: String, refresh: String = "r", org: String = "org") -> [String: Any] {
        ["accessToken": "a-\(account)", "refreshToken": "\(refresh)-\(account)", "expiresAt": 1,
         "accountUuid": account, "organizationUuid": org]
    }

    var refreshToken: String? { (item["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String }

    /// What a session's token renewal leaves behind: only the Keychain item changes.
    func renew(_ account: String, refresh: String, org: String = "org") throws {
        let value: [String: Any] = ["claudeAiOauth": oauth(account, refresh: refresh, org: org), "mcpOAuth": mcp]
        secrets.items["\(AccountSwitcher.claudeService)|u"] = try JSONSerialization.data(withJSONObject: value)
    }

    var item: [String: Any] {
        (try? JSONSerialization.jsonObject(with: secrets.read(service: AccountSwitcher.claudeService, account: "u") ?? Data())) as? [String: Any] ?? [:]
    }

    var config: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.paths.accountFile))) as? [String: Any] ?? [:]
    }

    /// What `claude auth login` leaves behind.
    func signIn(_ account: String, email: String, refresh: String = "r") throws {
        let value: [String: Any] = ["claudeAiOauth": oauth(account, refresh: refresh), "mcpOAuth": mcp]
        secrets.items["\(AccountSwitcher.claudeService)|u"] = try JSONSerialization.data(withJSONObject: value)
        var file = config
        if file.isEmpty { file = ["numStartups": 7, "projects": ["/x": ["allowedTools": []]]] }
        file["oauthAccount"] = ["accountUuid": account, "organizationUuid": "org", "emailAddress": email,
                                "organizationType": "claude_pro"]
        try JSONSerialization.data(withJSONObject: file).write(to: dir.paths.accountFile)
    }

    func signInBoth() throws {
        try signIn("A", email: "a@x.com")
        try switcher.saveActive()
        try signIn("B", email: "b@x.com")
        try switcher.saveActive()
    }

    @Test func saveActiveKeysByAccountAndOrg() throws {
        try signIn("A", email: "a@x.com")
        let saved = try #require(try switcher.saveActive())
        #expect(saved.key == "A:org")
        #expect(saved.email == "a@x.com")
        #expect(saved.plan == "Pro")
        #expect(switcher.saved().map(\.key) == ["A:org"])
        #expect(switcher.activeKey() == "A:org")
    }

    @Test func switchKeepsOtherKeys() throws {
        try signInBoth()
        try switcher.switchTo("A:org")
        #expect((item["claudeAiOauth"] as? [String: Any])?["accountUuid"] as? String == "A")
        #expect(NSDictionary(dictionary: item["mcpOAuth"] as? [String: Any] ?? [:]).isEqual(to: mcp))
    }

    @Test func switchReplacesOnlyOAuthAccount() throws {
        try signInBoth()
        try switcher.switchTo("A:org")
        #expect((config["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "a@x.com")
        #expect(config["numStartups"] as? Int == 7)
        #expect((config["projects"] as? [String: Any])?["/x"] != nil)
        let mode = try FileManager.default.attributesOfItem(atPath: dir.paths.accountFile.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func refusesCredentialsItDoesntRecognize() throws {
        try signInBoth()
        let writes = secrets.writes
        secrets.items["\(AccountSwitcher.claudeService)|u"] = Data("sealed:abc".utf8)
        #expect(throws: SwitchError.unrecognizedCredentials) { try switcher.switchTo("A:org") }
        secrets.items["\(AccountSwitcher.claudeService)|u"] = try JSONSerialization.data(
            withJSONObject: ["claudeAiOauth": ["accessToken": "x", "accountUuid": "B"]])
        #expect(throws: SwitchError.unrecognizedCredentials) { try switcher.switchTo("A:org") }
        #expect(secrets.writes == writes)
    }

    @Test func lockedConfigRollsBackKeychain() throws {
        try signInBoth()
        let before = secrets.read(service: AccountSwitcher.claudeService, account: "u")
        let lock = URL(fileURLWithPath: dir.paths.accountFile.path + ".lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        #expect(throws: SwitchError.configLocked) { try switcher.switchTo("A:org") }
        #expect(secrets.read(service: AccountSwitcher.claudeService, account: "u") == before)
        #expect((config["oauthAccount"] as? [String: Any])?["accountUuid"] as? String == "B")
    }

    @Test func staleLockIsTakenOver() throws {
        try signInBoth()
        let lock = URL(fileURLWithPath: dir.paths.accountFile.path + ".lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-11)], ofItemAtPath: lock.path)
        try switcher.switchTo("A:org")
        #expect(switcher.activeKey() == "A:org")
        #expect(!FileManager.default.fileExists(atPath: lock.path))
    }

    @Test func revertedRenewalIsSavedAndReapplied() throws {
        try signInBoth()
        let change = try #require(try switcher.switchTo("A:org"))
        // A session still on B renews B's token and writes it back.
        try renew("B", refresh: "r2")
        #expect(try switcher.reapplyIfReverted(change))
        #expect(switcher.activeKey() == "A:org")
        try switcher.switchTo("B:org")
        #expect(refreshToken == "r2-B")
    }

    @Test func aDeliberateSwitchElsewhereIsLeftAlone() throws {
        try signInBoth()
        let change = try #require(try switcher.switchTo("A:org"))
        // `claude /login` or the CLI moves the account file too, unlike a renewal.
        try signIn("B", email: "b@x.com", refresh: "r3")
        #expect(try !switcher.reapplyIfReverted(change))
        #expect(switcher.activeKey() == "B:org")
    }

    @Test func aRenewalOfTheChosenAccountIsKept() throws {
        try signInBoth()
        let change = try #require(try switcher.switchTo("A:org"))
        try renew("A", refresh: "r5")
        #expect(try !switcher.reapplyIfReverted(change))
        try renew("B", refresh: "r2")
        #expect(try switcher.reapplyIfReverted(change))
        #expect(refreshToken == "r5-A")
    }

    @Test func guardKeepsGoingAfterAFailedWrite() throws {
        try signInBoth()
        let change = try #require(try switcher.switchTo("A:org"))
        try renew("B", refresh: "r2")
        secrets.failWrites = 1
        #expect(switcher.guardSwitch(change, for: 0.2, every: 0.01) == 1)
        #expect(switcher.activeKey() == "A:org")
    }

    @Test func anUnsavedRenewalIsKeptWhenTheFilesDisagree() throws {
        try signInBoth()
        try renew("B", refresh: "r2")
        // Mid-change: the account file already names A.
        var file = config
        file["oauthAccount"] = ["accountUuid": "A", "organizationUuid": "org", "emailAddress": "a@x.com"]
        try JSONSerialization.data(withJSONObject: file).write(to: dir.paths.accountFile)
        try switcher.switchTo("A:org")
        try switcher.switchTo("B:org")
        #expect(refreshToken == "r2-B")
    }

    @Test func aLoginItNeverSavedIsNotOverwritten() throws {
        try signInBoth()
        try renew("C", refresh: "r")
        #expect(throws: SwitchError.self) { try switcher.switchTo("A:org") }
        #expect(switcher.activeKey() == "C:org")
    }

    @Test func rollbackNeverUndoesSomeoneElsesWrite() throws {
        try signInBoth()
        let lock = URL(fileURLWithPath: dir.paths.accountFile.path + ".lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        secrets.afterWrite = { [secrets] service in
            guard service == AccountSwitcher.claudeService else { return }
            secrets.afterWrite = nil
            try? self.renew("B", refresh: "r9")
        }
        #expect(throws: SwitchError.configLocked) { try switcher.switchTo("A:org") }
        #expect(refreshToken == "r9-B")
    }

    @Test func aLockItCantClearTimesOut() throws {
        try signInBoth()
        let lock = URL(fileURLWithPath: dir.paths.accountFile.path + ".lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-60)], ofItemAtPath: lock.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.url.path) }
        let start = Date.now
        #expect(throws: SwitchError.configLocked) { try switcher.switchTo("A:org") }
        #expect(Date.now.timeIntervalSince(start) < 2)
        #expect(switcher.activeKey() == "B:org")
    }

    @Test func anotherOrganizationOfTheSameAccountIsNotMixedUp() throws {
        try signIn("A", email: "a@x.com")
        try renew("A", refresh: "r", org: "team")
        #expect(try switcher.saveActive() == nil)
    }

    @Test func aSymlinkedAccountFileStaysASymlink() throws {
        try signInBoth()
        let real = dir.url.appending(path: "dotfiles/claude.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: dir.paths.accountFile, to: real)
        try FileManager.default.createSymbolicLink(at: dir.paths.accountFile, withDestinationURL: real)
        try switcher.switchTo("A:org")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: dir.paths.accountFile.path)) != nil)
        #expect((config["oauthAccount"] as? [String: Any])?["accountUuid"] as? String == "A")
    }

    @Test func guardPutsTheChosenLoginBackAndCounts() throws {
        try signInBoth()
        let change = try #require(try switcher.switchTo("A:org"))
        try renew("B", refresh: "r2")
        #expect(switcher.guardSwitch(change, for: 0.05, every: 0.01) == 1)
        #expect(switcher.activeKey() == "A:org")
    }

    @Test func aNewerSwitchEndsTheEarliersGuard() throws {
        try signInBoth()
        let change = try #require(try switcher.switchTo("A:org"))
        let done = DispatchSemaphore(value: 0)
        let switcher = switcher
        DispatchQueue.global().async {
            switcher.guardSwitch(change, for: 1, every: 0.02)
            done.signal()
        }
        Thread.sleep(forTimeInterval: 0.1)
        try switcher.switchTo("B:org")
        done.wait()
        #expect(switcher.activeKey() == "B:org")
    }

    @Test func anAccountItDoesntKnowIsLeftAlone() throws {
        try signInBoth()
        let change = try #require(try switcher.switchTo("A:org"))
        try renew("C", refresh: "r")
        #expect(try !switcher.reapplyIfReverted(change))
        #expect(switcher.activeKey() == "C:org")
    }

    @Test func switchingToTheActiveAccountWritesNothing() throws {
        try signInBoth()
        let writes = secrets.writes
        try switcher.switchTo("B:org")
        #expect(secrets.writes == writes)
    }

    @Test func forgetAllLeavesNoSavedLoginBehind() throws {
        try signInBoth()
        switcher.forgetAll()
        #expect(switcher.saved().isEmpty)
        #expect(!secrets.items.keys.contains { $0.hasPrefix(AccountSwitcher.savedService) })
        #expect(switcher.activeKey() == "B:org")
    }

    @Test func forgetRemovesOnlyThatLogin() throws {
        try signInBoth()
        switcher.forget("A:org")
        #expect(switcher.saved().map(\.key) == ["B:org"])
        #expect(secrets.read(service: AccountSwitcher.savedService, account: "A:org") == nil)
        #expect(throws: SwitchError.notSaved) { try switcher.switchTo("A:org") }
    }
}

@Suite struct JSONTextTests {
    @Test func replacesOneValueAndKeepsEveryOtherByte() throws {
        let text = "{\n  \"a\": 0.1,\n  \"s\": \"has } and \\\" and {\",\n  \"oauthAccount\": {\"x\": [1, {\"y\": \"}\"}]},\n  \"z\": 1.5e-7\n}"
        let result = try #require(JSONText.replacing("oauthAccount", in: Data(text.utf8), with: Data(#"{"x":2}"#.utf8)))
        #expect(String(decoding: result, as: UTF8.self)
                == "{\n  \"a\": 0.1,\n  \"s\": \"has } and \\\" and {\",\n  \"oauthAccount\": {\"x\":2},\n  \"z\": 1.5e-7\n}")
        #expect(JSONText.value(of: "z", in: Data(text.utf8)) == Data("1.5e-7".utf8))
        #expect(JSONText.replacing("missing", in: Data(text.utf8), with: Data("1".utf8)) == nil)
        #expect(JSONText.replacing("a", in: Data(text.utf8), with: Data("{".utf8)) == nil)
    }
}

@Suite struct SecurityCLITests {
    @Test func writesPlainValuesQuotedAndOthersAsHex() {
        let plain = SecurityCLI.command(for: Data(#"{"a":"q\"x","b":"Tăng"}"#.utf8), service: "S v", account: "u")
        #expect(plain == "add-generic-password -U -a \"u\" -s \"S v\" -w \"{\\\"a\\\":\\\"q\\\\\\\"x\\\",\\\"b\\\":\\\"Tăng\\\"}\"\n")
        #expect(SecurityCLI.command(for: Data("a\nb".utf8), service: "s", account: "u")?.contains("-X 610a62") == true)
        #expect(SecurityCLI.command(for: Data(String(repeating: "x", count: 5000).utf8), service: "s", account: "u") == nil)
    }
}
