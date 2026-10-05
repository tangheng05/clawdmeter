import Foundation

public struct TokenUsage: Equatable, Sendable {
    public var input = 0, output = 0, cacheRead = 0, cacheWrite5m = 0, cacheWrite1h = 0

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }

    public var total: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }
}

/// API prices in dollars per million tokens.
public struct ModelPrice: Equatable, Sendable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double

    public func cost(of usage: TokenUsage) -> Double {
        let dollars = Double(usage.input) * input + Double(usage.output) * output + Double(usage.cacheRead) * cacheRead
            + Double(usage.cacheWrite5m) * input * 1.25 + Double(usage.cacheWrite1h) * input * 2
        return dollars / 1_000_000
    }

    /// Longest prefix first, so "claude-opus-5-5" never falls through to "claude-opus-5".
    private static let table: [(prefix: String, price: ModelPrice)] = [
        ("claude-fable-5-1", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", ModelPrice(input: 10, output: 50, cacheRead: 1)),
        ("claude-mythos-5", ModelPrice(input: 10, output: 50, cacheRead: 1)),
        ("claude-opus-5-5", ModelPrice(input: 4, output: 20, cacheRead: 0.2)),
        ("claude-opus-5", ModelPrice(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-8", ModelPrice(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-7", ModelPrice(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-6", ModelPrice(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-sonnet-5-5", ModelPrice(input: 2, output: 10, cacheRead: 0.2)),
        ("claude-sonnet-5", ModelPrice(input: 2, output: 10, cacheRead: 0.2)),
        ("claude-sonnet-4-6", ModelPrice(input: 3, output: 15, cacheRead: 0.3)),
        ("claude-haiku-4-5", ModelPrice(input: 1, output: 5, cacheRead: 0.1)),
    ].sorted { $0.prefix.count > $1.prefix.count }

    /// Also matches provider-prefixed ids such as "anthropic.claude-sonnet-4-6".
    public static func lookup(_ model: String) -> ModelPrice? {
        guard let start = model.range(of: "claude-") else { return nil }
        let id = model[start.lowerBound...]
        return table.first { id.hasPrefix($0.prefix) }?.price
    }
}

public struct DayTotal: Codable, Equatable, Sendable {
    public var tokens = 0
    public var cost = 0.0
    /// Tokens from models without a known price, so not in `cost`.
    public var unpricedTokens = 0

    public init(tokens: Int = 0, cost: Double = 0, unpricedTokens: Int = 0) {
        self.tokens = tokens
        self.cost = cost
        self.unpricedTokens = unpricedTokens
    }

    static func + (a: DayTotal, b: DayTotal) -> DayTotal {
        DayTotal(tokens: a.tokens + b.tokens, cost: a.cost + b.cost, unpricedTokens: a.unpricedTokens + b.unpricedTokens)
    }

    static func += (a: inout DayTotal, b: DayTotal) {
        a = a + b
    }
}

public struct SpendSummary: Codable, Equatable, Sendable {
    public let today: DayTotal
    public let yesterday: DayTotal
    public let last30: DayTotal

    public var hasUnpriced: Bool { last30.unpricedTokens > 0 }
}

/// What Claude Code's local logs would cost at API prices. Each refresh reads only what was
/// appended since the last one.
public final class SpendIndex: @unchecked Sendable {
    private struct Reply {
        let date: Date
        let total: DayTotal

        /// A reply is logged once per content block, and its output count can grow along the way.
        static func larger(_ a: Reply, _ b: Reply) -> Reply {
            b.total.tokens > a.total.tokens ? b : a
        }
    }

    private struct FileState {
        var offset = 0
        var replies: [String: Reply] = [:]
    }

    private let paths: ClaudePaths
    private let lock = NSLock()
    private var files: [String: FileState] = [:]
    private static let marker = Array(#""usage""#.utf8)
    private static let newline = UInt8(ascii: "\n")
    private static let bufferSize = 1 << 20
    private var buffer = [UInt8](repeating: 0, count: bufferSize)
    /// Building a formatter per line dominated a full scan; reading from a shared one is thread-safe.
    nonisolated(unsafe) private static let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(paths: ClaudePaths) {
        self.paths = paths
    }

    public func refresh(now: Date = .now, calendar: Calendar = .current) -> SpendSummary {
        lock.lock()
        defer { lock.unlock() }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let monthStart = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let cutoff = calendar.date(byAdding: .day, value: -1, to: monthStart) ?? monthStart

        var present = Set<String>()
        for file in logFiles(modifiedSince: cutoff) {
            present.insert(file.path)
            update(file, droppingBefore: cutoff)
        }
        files = files.filter { present.contains($0.key) }

        // A resumed conversation repeats earlier replies in its new log, so dedupe across files.
        var replies: [String: Reply] = [:]
        for state in files.values {
            replies.merge(state.replies, uniquingKeysWith: Reply.larger)
        }
        var days: [Date: DayTotal] = [:]
        for reply in replies.values where reply.date >= monthStart {
            days[calendar.startOfDay(for: reply.date), default: DayTotal()] += reply.total
        }
        return SpendSummary(today: days[today] ?? DayTotal(), yesterday: days[yesterday] ?? DayTotal(),
                            last30: days.values.reduce(DayTotal(), +))
    }

    private func logFiles(modifiedSince cutoff: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: paths.projectsDir, includingPropertiesForKeys: keys) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { url in
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return false }
            return (values.contentModificationDate ?? .distantPast) >= cutoff
        }
    }

    private func update(_ file: URL, droppingBefore cutoff: Date) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        var state = files[file.path] ?? FileState()
        guard let size = try? handle.seekToEnd() else { return }
        if size < state.offset { state = FileState() }
        guard size > state.offset, (try? handle.seek(toOffset: UInt64(state.offset))) != nil else { return }

        // One reused buffer instead of a fresh copy per read, which left the app tens of MB larger.
        let decoder = JSONDecoder()
        var filled = 0
        while true {
            if filled == buffer.count { buffer += [UInt8](repeating: 0, count: buffer.count) }
            let count = buffer.withUnsafeMutableBytes { read(handle.fileDescriptor, $0.baseAddress! + filled, $0.count - filled) }
            guard count > 0 else { break }
            filled += count
            // A trailing line without its newline is still being written; it's read next time.
            guard let lastNewline = buffer[..<filled].lastIndex(of: Self.newline) else { continue }
            autoreleasepool {
                for line in buffer[...lastNewline].split(separator: Self.newline) where Self.mentionsUsage(line) {
                    guard let (id, reply) = Self.parse(Data(line), decoder: decoder), reply.date >= cutoff else { continue }
                    state.replies[id] = state.replies[id].map { Reply.larger($0, reply) } ?? reply
                }
            }
            let consumed = lastNewline + 1
            state.offset += consumed
            buffer.withUnsafeMutableBytes { _ = memmove($0.baseAddress!, $0.baseAddress! + consumed, filled - consumed) }
            filled -= consumed
        }
        // Back to normal size after a line longer than the buffer.
        if buffer.count > Self.bufferSize { buffer = [UInt8](repeating: 0, count: Self.bufferSize) }
        files[file.path] = state
    }

    /// Searches the bytes in place; `Data.range(of:)` copied every line first, tool output included.
    private static func mentionsUsage(_ line: ArraySlice<UInt8>) -> Bool {
        line.withUnsafeBytes { bytes in
            marker.withUnsafeBytes { needle in
                memmem(bytes.baseAddress, bytes.count, needle.baseAddress, needle.count) != nil
            }
        }
    }

    /// Only the fields that matter. Decoding skips the rest of a log line, like the reply's text,
    /// instead of building objects for it.
    private struct LogLine: Decodable {
        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }
        struct Usage: Decodable {
            struct CacheCreation: Decodable {
                let ephemeral_5m_input_tokens: Int?
                let ephemeral_1h_input_tokens: Int?
            }
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_read_input_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_creation: CacheCreation?
            let speed: String?
        }
        let type: String?
        let timestamp: String?
        let message: Message?
    }

    private static func parse(_ line: Data, decoder: JSONDecoder) -> (String, Reply)? {
        guard let log = try? decoder.decode(LogLine.self, from: line),
              log.type == "assistant",
              let id = log.message?.id,
              let usage = log.message?.usage,
              let stamp = log.timestamp,
              let date = timestamps.date(from: stamp) ?? Account.parseDate(stamp) else { return nil }
        var tokens = TokenUsage(input: usage.input_tokens ?? 0, output: usage.output_tokens ?? 0,
                                cacheRead: usage.cache_read_input_tokens ?? 0)
        if let split = usage.cache_creation {
            tokens.cacheWrite5m = split.ephemeral_5m_input_tokens ?? 0
            tokens.cacheWrite1h = split.ephemeral_1h_input_tokens ?? 0
        } else {
            tokens.cacheWrite5m = usage.cache_creation_input_tokens ?? 0
        }
        guard tokens.total > 0 else { return nil }

        let total: DayTotal
        if let price = log.message?.model.flatMap(ModelPrice.lookup) {
            let fast = usage.speed == "fast"
            total = DayTotal(tokens: tokens.total, cost: price.cost(of: tokens) * (fast ? 2 : 1))
        } else {
            total = DayTotal(tokens: tokens.total, unpricedTokens: tokens.total)
        }
        return (id, Reply(date: date, total: total))
    }
}
