import Foundation

/// Edits one value as text: re-encoding through JSONSerialization changes numbers like 0.1.
enum JSONText {
    static func valueRange(of key: String, in text: [UInt8]) -> Range<Int>? {
        var i = 0
        func skipSpace() { while i < text.count, [0x20, 0x09, 0x0A, 0x0D].contains(text[i]) { i += 1 } }
        func skipString() -> Range<Int>? {
            guard i < text.count, text[i] == UInt8(ascii: "\"") else { return nil }
            let start = i + 1
            i += 1
            while i < text.count {
                if text[i] == UInt8(ascii: "\\") { i += 2; continue }
                if text[i] == UInt8(ascii: "\"") { i += 1; return start..<(i - 1) }
                i += 1
            }
            return nil
        }
        func skipValue() -> Bool {
            if i < text.count, text[i] == UInt8(ascii: "\"") { return skipString() != nil }
            var depth = 0
            while i < text.count {
                switch text[i] {
                case UInt8(ascii: "\""): if skipString() == nil { return false }; continue
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    if depth == 0 { return true }
                    depth -= 1
                    if depth == 0 { i += 1; return true }
                case UInt8(ascii: ","), 0x20, 0x09, 0x0A, 0x0D: if depth == 0 { return true }
                default: break
                }
                i += 1
            }
            return depth == 0
        }
        skipSpace()
        guard i < text.count, text[i] == UInt8(ascii: "{") else { return nil }
        i += 1
        let wanted = Array(key.utf8)
        while true {
            skipSpace()
            guard let name = skipString() else { return nil }
            skipSpace()
            guard i < text.count, text[i] == UInt8(ascii: ":") else { return nil }
            i += 1
            skipSpace()
            let start = i
            guard skipValue() else { return nil }
            if Array(text[name]) == wanted { return start..<i }
            skipSpace()
            guard i < text.count, text[i] == UInt8(ascii: ",") else { return nil }
            i += 1
        }
    }

    static func value(of key: String, in data: Data) -> Data? {
        let bytes = [UInt8](data)
        return valueRange(of: key, in: bytes).map { Data(bytes[$0]) }
    }

    /// Nil when the key isn't there or the result wouldn't parse.
    static func replacing(_ key: String, in data: Data, with value: Data) -> Data? {
        var bytes = [UInt8](data)
        guard let range = valueRange(of: key, in: bytes) else { return nil }
        bytes.replaceSubrange(range, with: [UInt8](value))
        let result = Data(bytes)
        return (try? JSONSerialization.jsonObject(with: result)) is [String: Any] ? result : nil
    }
}

enum ConfigFile {
    static let staleLockAge: TimeInterval = 10

    /// Under the same `<file>.lock` directory Claude Code takes, so neither overwrites the other.
    static func replaceOAuthAccount(_ account: Data, in file: URL, lockTimeout: TimeInterval) throws {
        // Dotfile managers often symlink it; replacing the link would cut it loose.
        let file = file.resolvingSymlinksInPath()
        let lock = URL(fileURLWithPath: file.path + ".lock")
        let held = try acquire(lock, timeout: lockTimeout)
        defer { if inode(lock) == held { try? FileManager.default.removeItem(at: lock) } }
        guard let current = try? Data(contentsOf: file),
              let updated = JSONText.replacing("oauthAccount", in: current, with: account) else {
            throw SwitchError.writeFailed("Claude Code's account file couldn't be read.")
        }
        let temp = file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).clawdmeter-\(UUID().uuidString)")
        do {
            try updated.write(to: temp)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            guard rename(temp.path, file.path) == 0 else { throw SwitchError.writeFailed("Claude Code's account file couldn't be saved.") }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error as? SwitchError ?? SwitchError.writeFailed("Claude Code's account file couldn't be saved.")
        }
    }

    /// Returns the lock's inode, so only this lock is ever removed.
    private static func acquire(_ lock: URL, timeout: TimeInterval) throws -> UInt64 {
        let deadline = Date.now.addingTimeInterval(timeout)
        while true {
            if mkdir(lock.path, 0o755) == 0, let held = inode(lock) { return held }
            let modified = (try? FileManager.default.attributesOfItem(atPath: lock.path))?[.modificationDate] as? Date
            if let modified, Date.now.timeIntervalSince(modified) > staleLockAge {
                // Renamed first, so a lock someone takes meanwhile is never the one deleted.
                let aside = lock.path + ".stale-\(UUID().uuidString)"
                if rename(lock.path, aside) == 0 { try? FileManager.default.removeItem(atPath: aside) }
            }
            guard Date.now < deadline else { throw SwitchError.configLocked }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static func inode(_ url: URL) -> UInt64? {
        var info = stat()
        return stat(url.path, &info) == 0 ? UInt64(info.st_ino) : nil
    }
}
