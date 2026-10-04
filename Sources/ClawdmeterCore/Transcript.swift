import Foundation

/// Context window sizes per model, learned from the status line of terminal sessions.
public enum ContextWindows {
    public static func load(_ paths: ClaudePaths) -> [String: Int] {
        guard let data = try? Data(contentsOf: paths.windowsFile) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    static func record(model: String, size: Int, paths: ClaudePaths) {
        var windows = load(paths)
        guard size > 0, windows[model] != size else { return }
        windows[model] = size
        if let data = try? JSONEncoder().encode(windows) { try? writeAtomically(data, to: paths.windowsFile) }
    }
}

public struct TranscriptContext: Equatable, Sendable {
    public let tokens: Int
    /// nil when the model's window size hasn't been seen yet; a guess could be off by 5x.
    public let percent: Double?

    public init(tokens: Int, percent: Double?) {
        self.tokens = tokens
        self.percent = percent
    }
}

public enum TranscriptUsage {
    /// Tokens in context after the latest reply, from the end of a conversation log.
    public static func latest(in file: URL) -> (tokens: Int, model: String?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let tail = min(size, 256 * 1024)
        try? handle.seek(toOffset: size - tail)
        guard let data = try? handle.readToEnd() else { return nil }

        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  json["type"] as? String == "assistant",
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let count = { (key: String) in (usage[key] as? NSNumber)?.intValue ?? 0 }
            let tokens = count("input_tokens") + count("cache_read_input_tokens") + count("cache_creation_input_tokens")
            return (tokens, message["model"] as? String)
        }
        return nil
    }
}

/// Reads conversation logs only when they change, since they grow on every reply.
public final class TranscriptCache {
    private struct Entry {
        let file: URL
        var modified: Date?
        var usage: (tokens: Int, model: String?)?
    }

    private let paths: ClaudePaths
    private var entries: [String: Entry] = [:]

    public init(paths: ClaudePaths) {
        self.paths = paths
    }

    public func context(forSession sessionId: String, windows: [String: Int]) -> TranscriptContext? {
        guard var entry = entries[sessionId] ?? locate(sessionId) else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: entry.file.path))?[.modificationDate] as? Date
        if modified != entry.modified || entry.usage == nil {
            entry.modified = modified
            entry.usage = TranscriptUsage.latest(in: entry.file)
        }
        entries[sessionId] = entry
        guard let usage = entry.usage else { return nil }
        let window = usage.model.flatMap { windows[$0] }
        return TranscriptContext(tokens: usage.tokens,
                                 percent: window.map { min(100, Double(usage.tokens) / Double($0) * 100) })
    }

    private func locate(_ sessionId: String) -> Entry? {
        guard sanitizedSessionId(sessionId) == sessionId else { return nil }
        let fm = FileManager.default
        let projects = (try? fm.contentsOfDirectory(at: paths.projectsDir, includingPropertiesForKeys: nil)) ?? []
        for project in projects {
            let file = project.appending(path: "\(sessionId).jsonl")
            if fm.fileExists(atPath: file.path) { return Entry(file: file, modified: nil, usage: nil) }
        }
        return nil
    }
}
