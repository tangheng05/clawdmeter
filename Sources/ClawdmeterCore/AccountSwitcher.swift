import Foundation

public enum SwitchError: Error, Equatable, LocalizedError {
    case unrecognizedCredentials, notSaved, configLocked, busy, writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unrecognizedCredentials:
            "Claude Code stores its login in a way Clawdmeter doesn't recognize, so it can't switch directly. Use Add account to sign in."
        case .notSaved: "That account isn't saved yet. Add it first."
        case .configLocked: "Claude Code was busy saving its settings. Try again in a moment."
        case .busy: "Claude Code was changing its login just then. Try again in a moment."
        case .writeFailed(let reason): reason
        }
    }
}

/// The login itself stays in the Keychain.
public struct SavedLogin: Codable, Equatable, Sendable {
    public let key: String
    public let email: String?
    public let plan: String?
    public let organization: String?
    public let savedAt: Date
}

/// What a switch changed, so the guard afterwards can tell a renewal from a deliberate change.
public struct AccountChange: Sendable {
    public let key: String
    let previous: String
    let generation: Int
}

/// Changes only `claudeAiOauth` in the Keychain item and `oauthAccount` in the account file.
public final class AccountSwitcher: @unchecked Sendable {
    public static let claudeService = "Claude Code-credentials"
    public static let savedService = "Clawdmeter-accounts"

    private let paths: ClaudePaths
    private let secrets: SecretStore
    private let user: String
    private let lockTimeout: TimeInterval
    private let lock = NSLock()
    /// Bumped by every switch, so a guard from an earlier one stops instead of undoing a newer one.
    private var generation = 0

    public init(paths: ClaudePaths = ClaudePaths(), secrets: SecretStore = SecurityCLI(),
                user: String = AccountSwitcher.defaultUser, lockTimeout: TimeInterval = 5) {
        self.paths = paths
        self.secrets = secrets
        self.user = user
        self.lockTimeout = lockTimeout
    }

    public static var defaultUser: String {
        let user = ProcessInfo.processInfo.environment["USER"] ?? ""
        return user.isEmpty ? NSUserName() : user
    }

    public var isSupported: Bool { paths.isDefault && activeKey() != nil }

    public func saved() -> [SavedLogin] {
        lock.withLock { loadIndex() }
    }

    public func activeKey() -> String? {
        credentials()?.key
    }

    /// Nil when not signed in with claude.ai, or Claude Code's two files disagree mid-change.
    @discardableResult
    public func saveActive() throws -> SavedLogin? {
        try lock.withLock { try saveActiveLocked() }
    }

    /// Nil when that account is already signed in.
    @discardableResult
    public func switchTo(_ key: String) throws -> AccountChange? {
        try lock.withLock {
            for _ in 0..<3 {
                do { return try switchLocked(to: key) } catch SwitchError.busy { Thread.sleep(forTimeInterval: 0.2) }
            }
            throw SwitchError.busy
        }
    }

    /// Ends any guard still running, for a sign-in the user starts.
    public func cancelGuards() {
        lock.withLock { generation += 1 }
    }

    /// Puts the chosen login back when a session renews the one it replaced and writes that back.
    /// A change that also moved the account file is deliberate (`/login`, the CLI) and stays.
    public func reapplyIfReverted(_ change: AccountChange) throws -> Bool {
        try lock.withLock {
            guard change.generation == generation else { throw CancellationError() }
            guard let current = credentials() else { return false }
            if current.key == change.key {
                try updateSaved(current)
                return false
            }
            guard current.key == change.previous, configKey() == change.key,
                  let saved = secrets.read(service: Self.savedService, account: change.key),
                  let oauth = JSONText.value(of: "claudeAiOauth", in: saved) else { return false }
            // The old refresh token is spent, so keep the renewed one.
            try updateSaved(current)
            try apply(oauth: oauth, account: nil, over: current)
            return true
        }
    }

    /// Blocks while it watches; returns how many times it put the login back.
    @discardableResult
    public func guardSwitch(_ change: AccountChange, for duration: TimeInterval = 60, every interval: TimeInterval = 5,
                            maxReapplies: Int = 3) -> Int {
        let end = Date.now.addingTimeInterval(duration)
        var reapplied = 0
        while Date.now < end, reapplied < maxReapplies {
            do {
                if try reapplyIfReverted(change) { reapplied += 1 }
            } catch is CancellationError {
                break
            } catch {
                // Claude Code was mid-write; the next pass tries again.
            }
            Thread.sleep(forTimeInterval: interval)
        }
        return reapplied
    }

    public func forgetAll() {
        lock.withLock {
            for login in loadIndex() { secrets.delete(service: Self.savedService, account: login.key) }
            try? FileManager.default.removeItem(at: indexFile)
        }
    }

    public func forget(_ key: String) {
        lock.withLock {
            secrets.delete(service: Self.savedService, account: key)
            saveIndex(loadIndex().filter { $0.key != key })
        }
    }

    private func switchLocked(to key: String) throws -> AccountChange? {
        guard loadIndex().contains(where: { $0.key == key }),
              let saved = secrets.read(service: Self.savedService, account: key),
              let oauth = JSONText.value(of: "claudeAiOauth", in: saved),
              let account = JSONText.value(of: "oauthAccount", in: saved) else { throw SwitchError.notSaved }
        guard let current = credentials() else { throw SwitchError.unrecognizedCredentials }
        if current.key == key { return nil }
        // Its newest refresh token must be kept before the item is overwritten.
        if try saveActiveLocked() == nil {
            guard try updateSaved(current) else { throw SwitchError.busy }
        }
        try apply(oauth: oauth, account: account, over: current)
        generation += 1
        return AccountChange(key: key, previous: current.key, generation: generation)
    }

    /// Writes only if the item is still what was read, and rolls back only its own write.
    private func apply(oauth: Data, account: Data?, over current: Credentials) throws {
        guard let item = JSONText.replacing("claudeAiOauth", in: current.data, with: oauth) else {
            throw SwitchError.unrecognizedCredentials
        }
        guard secrets.read(service: Self.claudeService, account: user) == current.data else { throw SwitchError.busy }
        try secrets.write(item, service: Self.claudeService, account: user)
        guard let account else { return }
        do {
            try ConfigFile.replaceOAuthAccount(account, in: paths.accountFile, lockTimeout: lockTimeout)
        } catch {
            if secrets.read(service: Self.claudeService, account: user) == item {
                try? secrets.write(current.data, service: Self.claudeService, account: user)
            }
            throw error
        }
    }

    /// Copies the current login into its saved copy. False when it was never saved.
    @discardableResult
    private func updateSaved(_ current: Credentials) throws -> Bool {
        guard let saved = secrets.read(service: Self.savedService, account: current.key),
              let updated = JSONText.replacing("claudeAiOauth", in: saved, with: current.oauth) else { return false }
        if updated != saved { try secrets.write(updated, service: Self.savedService, account: current.key) }
        return true
    }

    private func configKey() -> String? {
        configOAuthAccount().flatMap(Self.key)
    }

    private static func key(_ config: (raw: Data, parsed: [String: Any])) -> String? {
        guard let account = config.parsed["accountUuid"] as? String else { return nil }
        return "\(account):\(config.parsed["organizationUuid"] as? String ?? "")"
    }

    @discardableResult
    private func saveActiveLocked() throws -> SavedLogin? {
        guard let current = credentials(), let config = configOAuthAccount(),
              Self.key(config) == current.key else { return nil }
        var blob = Data(#"{"claudeAiOauth":"#.utf8)
        blob += current.oauth + Data(#","oauthAccount":"#.utf8) + config.raw + Data("}".utf8)
        if secrets.read(service: Self.savedService, account: current.key) != blob {
            try secrets.write(blob, service: Self.savedService, account: current.key)
        }
        let login = SavedLogin(key: current.key, email: config.parsed["emailAddress"] as? String,
                               plan: Account.plan(config.parsed), organization: Account.organization(config.parsed),
                               savedAt: .now)
        var index = loadIndex()
        if let existing = index.first(where: { $0.key == login.key }),
           existing.email == login.email, existing.plan == login.plan, existing.organization == login.organization {
            return existing
        }
        index.removeAll { $0.key == login.key }
        index.append(login)
        saveIndex(index)
        return login
    }

    private struct Credentials {
        let data: Data
        /// `claudeAiOauth` exactly as Claude Code wrote it.
        let oauth: Data
        let key: String
    }

    /// Nil unless it's the plain JSON format this was built against.
    private func credentials() -> Credentials? {
        guard let data = secrets.read(service: Self.claudeService, account: user),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty,
              let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty,
              let account = oauth["accountUuid"] as? String, !account.isEmpty,
              let raw = JSONText.value(of: "claudeAiOauth", in: data) else { return nil }
        let organization = oauth["organizationUuid"] as? String ?? ""
        return Credentials(data: data, oauth: raw, key: "\(account):\(organization)")
    }

    private func configOAuthAccount() -> (raw: Data, parsed: [String: Any])? {
        guard let data = try? Data(contentsOf: paths.accountFile),
              let raw = JSONText.value(of: "oauthAccount", in: data),
              let parsed = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return nil }
        return (raw, parsed)
    }

    private var indexFile: URL { paths.appDir.appending(path: "accounts.json") }

    private func loadIndex() -> [SavedLogin] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: indexFile),
              let index = try? decoder.decode([SavedLogin].self, from: data) else { return [] }
        return index
    }

    private func saveIndex(_ index: [SavedLogin]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let sorted = index.sorted { ($0.email ?? $0.key) < ($1.email ?? $1.key) }
        guard let data = try? encoder.encode(sorted) else { return }
        try? writeAtomically(data, to: indexFile)
    }
}
