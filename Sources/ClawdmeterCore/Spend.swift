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

/// Dollars per million tokens.
public struct Rates: Codable, Equatable, Sendable {
    public var input, output, cacheRead, cacheWrite5m, cacheWrite1h: Double

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite5m: Double, cacheWrite1h: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }

    /// The usual cache write rates: 1.25x input for 5 minutes, 2x for an hour.
    static func standard(input: Double, output: Double, cacheRead: Double) -> Rates {
        Rates(input: input, output: output, cacheRead: cacheRead, cacheWrite5m: input * 1.25, cacheWrite1h: input * 2)
    }
}

public struct ModelPrice: Codable, Equatable, Sendable {
    public var standard: Rates
    /// Haiku 5.5 bills a whole request at these rates once its prompt, cache included, passes the threshold.
    public var longPrompt: Rates?
    public var longPromptThreshold: Int?

    public init(standard: Rates, longPrompt: Rates? = nil, longPromptThreshold: Int? = nil) {
        self.standard = standard
        self.longPrompt = longPrompt
        self.longPromptThreshold = longPromptThreshold
    }

    public func cost(of usage: TokenUsage) -> Double {
        let prompt = usage.input + usage.cacheRead + usage.cacheWrite5m + usage.cacheWrite1h
        var rates = standard
        if let longPrompt, let longPromptThreshold, prompt > longPromptThreshold { rates = longPrompt }
        let dollars = Double(usage.input) * rates.input + Double(usage.output) * rates.output
            + Double(usage.cacheRead) * rates.cacheRead
            + Double(usage.cacheWrite5m) * rates.cacheWrite5m + Double(usage.cacheWrite1h) * rates.cacheWrite1h
        return dollars / 1_000_000
    }

    /// Used until the pricing page has been fetched, and for models it no longer lists.
    public static let builtIn: [String: ModelPrice] = {
        func price(_ input: Double, _ output: Double, _ cacheRead: Double) -> ModelPrice {
            ModelPrice(standard: .standard(input: input, output: output, cacheRead: cacheRead))
        }
        return [
            "claude-fable-5-2": price(8, 40, 0.2),
            "claude-mythos-5-2": price(8, 40, 0.2),
            "claude-fable-5-1": price(10, 50, 0.25),
            "claude-mythos-5-1": price(10, 50, 0.25),
            "claude-fable-5": price(10, 50, 1),
            "claude-mythos-5": price(10, 50, 1),
            "claude-opus-5-5": price(4, 20, 0.2),
            "claude-opus-5": price(5, 25, 0.5),
            "claude-opus-4-8": price(5, 25, 0.5),
            "claude-opus-4-7": price(5, 25, 0.5),
            "claude-opus-4-6": price(5, 25, 0.5),
            "claude-opus-4-5": price(5, 25, 0.5),
            "claude-opus-4-1": price(15, 75, 1.5),
            "claude-opus-4": price(15, 75, 1.5),
            "claude-sonnet-5-5": price(2, 10, 0.1),
            "claude-sonnet-5": price(2, 10, 0.2),
            "claude-sonnet-4-6": price(3, 15, 0.3),
            "claude-sonnet-4-5": price(3, 15, 0.3),
            "claude-sonnet-4": price(3, 15, 0.3),
            "claude-haiku-5-5": ModelPrice(standard: .standard(input: 0.1, output: 0.5, cacheRead: 0.01),
                                           longPrompt: .standard(input: 0.5, output: 2.5, cacheRead: 0.05),
                                           longPromptThreshold: 100_000),
            "claude-haiku-4-5": price(1, 5, 0.1),
        ]
    }()

    public static func lookup(_ model: String) -> ModelPrice? {
        lookup(model, in: builtIn)
    }

    /// Matches provider prefixes and date or variant suffixes ("anthropic.…-v1:0", "…-20251101", "…[1m]"),
    /// but never a newer version: "claude-fable-5" doesn't price "claude-fable-5-2".
    public static func lookup(_ model: String, in table: [String: ModelPrice]) -> ModelPrice? {
        guard let start = model.range(of: "claude-") else { return nil }
        let id = model[start.lowerBound...]
        let key = table.keys.filter { id.hasPrefix($0) && isVariantSuffix(id.dropFirst($0.count)) }.max { $0.count < $1.count }
        return key.flatMap { table[$0] }
    }

    private static func isVariantSuffix(_ rest: Substring) -> Bool {
        if rest.isEmpty || rest.hasPrefix("@") || rest.hasPrefix("[") || rest.hasPrefix(":") || rest.hasPrefix("-v") {
            return true
        }
        let date = rest.dropFirst().prefix(while: \.isNumber)
        return rest.hasPrefix("-") && date.count == 8
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
    /// Priced when summed rather than when read, so a price fetched later applies to every reply.
    private struct Reply {
        let date: Date
        var model: String?
        let tokens: TokenUsage
        let fast: Bool

        /// A reply is logged once per content block, and its output count can grow along the way.
        static func larger(_ a: Reply, _ b: Reply) -> Reply {
            b.tokens.total > a.tokens.total ? b : a
        }
    }

    private struct FileState {
        var offset = 0
        var replies: [String: Reply] = [:]
    }

    private let paths: ClaudePaths
    private let lock = NSLock()
    private var files: [String: FileState] = [:]
    /// One shared copy of each model name, instead of one per reply.
    private var modelNames: [String: String] = [:]
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
        let table = LivePrices.table(paths)
        var prices: [String: ModelPrice?] = [:]
        var days: [Date: DayTotal] = [:]
        for reply in replies.values where reply.date >= monthStart {
            let tokens = reply.tokens.total
            var total = DayTotal(tokens: tokens, unpricedTokens: tokens)
            if let model = reply.model {
                if prices[model] == nil { prices[model] = ModelPrice.lookup(model, in: table) }
                if let price = prices[model] ?? nil {
                    total = DayTotal(tokens: tokens, cost: price.cost(of: reply.tokens) * (reply.fast ? 2 : 1))
                }
            }
            days[calendar.startOfDay(for: reply.date), default: DayTotal()] += total
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
                    guard let (id, parsed) = Self.parse(Data(line), decoder: decoder), parsed.date >= cutoff else { continue }
                    var reply = parsed
                    reply.model = reply.model.map(intern)
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

    private func intern(_ name: String) -> String {
        if let shared = modelNames[name] { return shared }
        modelNames[name] = name
        return name
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
        return (id, Reply(date: date, model: log.message?.model, tokens: tokens, fast: usage.speed == "fast"))
    }
}
