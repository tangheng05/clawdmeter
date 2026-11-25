import Foundation

public enum LivePrices {
    static let url = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing.md")!
    static let maxAge: TimeInterval = 86_400

    private struct Cache: Codable {
        let fetchedAt: Date
        let models: [String: ModelPrice]
    }

    public static func table(_ paths: ClaudePaths) -> [String: ModelPrice] {
        ModelPrice.builtIn.merging(load(paths)?.models ?? [:]) { _, fetched in fetched }
    }

    static func isDue(_ paths: ClaudePaths, now: Date) -> Bool {
        guard let cache = load(paths) else { return true }
        return now.timeIntervalSince(cache.fetchedAt) >= maxAge
    }

    /// True when new prices were saved.
    @discardableResult
    public static func refreshIfDue(_ paths: ClaudePaths, now: Date = .now) async -> Bool {
        guard isDue(paths, now: now) else { return false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 30
        var request = URLRequest(url: url)
        request.setValue("clawdmeter", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession(configuration: configuration).data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let models = parse(String(decoding: data, as: UTF8.self)),
              (try? save(models, paths: paths, at: now)) != nil else { return false }
        return true
    }

    static func save(_ models: [String: ModelPrice], paths: ClaudePaths, at date: Date) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: paths.appDir, withIntermediateDirectories: true)
        try writeAtomically(try encoder.encode(Cache(fetchedAt: date, models: models)), to: paths.pricesFile)
    }

    private static func load(_ paths: ClaudePaths) -> Cache? {
        guard let data = try? Data(contentsOf: paths.pricesFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Cache.self, from: data)
    }

    /// Nil unless every row reads cleanly, so a changed page can't replace good prices with bad ones.
    static func parse(_ markdown: String) -> [String: ModelPrice]? {
        let lines = markdown.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let heading = lines.firstIndex(of: "## Model pricing") else { return nil }
        let rows = lines[(heading + 1)...].prefix(while: { !$0.hasPrefix("## ") }).filter { $0.hasPrefix("|") }.map(cells)
        guard rows.count >= 3, rows[1].allSatisfy({ $0.allSatisfy { "-:".contains($0) } }) else { return nil }
        let header = rows[0].map { $0.lowercased() }
        func column(_ name: String) -> Int? { header.firstIndex { $0.hasPrefix(name) } }
        guard header.first == "model", let input = column("base input"), let write5m = column("5m cache"),
              let write1h = column("1h cache"), let read = column("cache hits"), let output = column("output") else { return nil }

        var standard: [String: Rates] = [:], long: [String: Rates] = [:], thresholds: [String: Int] = [:]
        for row in rows.dropFirst(2) {
            guard row.count == header.count, let (id, tier) = modelId(row[0]),
                  let rates = rates(row, input: input, output: output, read: read, write5m: write5m, write1h: write1h)
            else { return nil }
            switch tier {
            case .all, .upTo:
                guard standard[id] == nil else { return nil }
                standard[id] = rates
                if case .upTo(let tokens) = tier {
                    guard tokens >= 1_000 else { return nil }
                    thresholds[id] = tokens
                }
            case .over:
                guard long[id] == nil else { return nil }
                long[id] = rates
            }
        }
        guard Set(long.keys) == Set(thresholds.keys) else { return nil }
        var models: [String: ModelPrice] = [:]
        for (id, rates) in standard {
            models[id] = ModelPrice(standard: rates, longPrompt: long[id], longPromptThreshold: thresholds[id])
        }
        guard models.count >= 5, models.keys.contains(where: { ModelPrice.builtIn[$0] != nil }) else { return nil }
        return models
    }

    private static func cells(_ row: String) -> [String] {
        Array(row.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast())
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func rates(_ row: [String], input: Int, output: Int, read: Int, write5m: Int, write1h: Int) -> Rates? {
        guard let i = dollarAmount(row[input]), let o = dollarAmount(row[output]), let r = dollarAmount(row[read]),
              let w5 = dollarAmount(row[write5m]), let w1 = dollarAmount(row[write1h]),
              i > 0, r > 0, o > i, r < i, w5 >= i, w1 >= w5 else { return nil }
        return Rates(input: i, output: o, cacheRead: r, cacheWrite5m: w5, cacheWrite1h: w1)
    }

    private enum Tier { case all, upTo(Int), over }

    /// "Claude Opus 5.5" → claude-opus-5-5. Links and notes in parentheses are dropped.
    private static func modelId(_ cell: String) -> (String, Tier)? {
        var name = cell, tier = Tier.all
        if let open = name.firstIndex(of: "(") {
            let note = String(name[open...])
            name = String(name[..<open])
            if note.contains("prompts up to") {
                guard let tokens = Int(note.filter(\.isNumber)) else { return nil }
                tier = .upTo(tokens)
            } else if note.contains("prompts over") {
                tier = .over
            }
        }
        let words = name.lowercased().split(separator: " ")
        guard words.first == "claude", words.count >= 3 else { return nil }
        let id = words.joined(separator: "-").replacingOccurrences(of: ".", with: "-")
        guard id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return (id, tier)
    }

    /// "$0.20 / MTok<sup>1</sup>" → 0.2.
    private static func dollarAmount(_ cell: String) -> Double? {
        guard cell.hasPrefix("$"), let slash = cell.firstIndex(of: "/") else { return nil }
        return Double(cell.dropFirst().prefix(upTo: slash).trimmingCharacters(in: .whitespaces))
    }
}
