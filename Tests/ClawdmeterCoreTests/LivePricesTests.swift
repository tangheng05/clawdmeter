import Foundation
import Testing
@testable import ClawdmeterCore

@Suite struct LivePricesTests {
    static let page = """
    ## Model pricing

    The following table shows pricing for all Claude models:

    | Model | Base input tokens | 5m cache writes | 1h cache writes | Cache hits and refreshes | Output tokens |
    | :---- | :---- | :---- | :---- | :---- | :---- |
    | Claude Fable 5.2 | $8 / MTok | $10 / MTok | $16 / MTok | $0.20 / MTok<sup>1</sup> | $40 / MTok |
    | Claude Mythos 5.2 ([limited availability](https://support.claude.com/en/articles/14604842)) | $8 / MTok | $10 / MTok | $16 / MTok | $0.20 / MTok<sup>1</sup> | $40 / MTok |
    | Claude Fable 5.1 | $10 / MTok | $12.50 / MTok | $20 / MTok | $0.25 / MTok<sup>1</sup> | $50 / MTok |
    | Claude Fable 5 | $10 / MTok | $12.50 / MTok | $20 / MTok | $1 / MTok | $50 / MTok |
    | Claude Opus 5.5 | $4 / MTok | $5 / MTok | $8 / MTok | $0.20 / MTok<sup>2</sup> | $20 / MTok |
    | Claude Opus 5 | $5 / MTok | $6.25 / MTok | $10 / MTok | $0.50 / MTok | $25 / MTok |
    | Claude Opus 4.1 ([retired, except on Bedrock](https://platform.claude.com/docs/en/about-claude/model-deprecations)) | $15 / MTok | $18.75 / MTok | $30 / MTok | $1.50 / MTok | $75 / MTok |
    | Claude Sonnet 5.5 | $2 / MTok | $2.50 / MTok | $4 / MTok | $0.10 / MTok<sup>2</sup> | $10 / MTok |
    | Claude Sonnet 5 | $2 / MTok<sup>3</sup> | $2.50 / MTok | $4 / MTok | $0.20 / MTok | $10 / MTok<sup>3</sup> |
    | Claude Haiku 5.5 (for prompts up to 100,000 tokens) | $0.10 / MTok | $0.125 / MTok | $0.20 / MTok | $0.01 / MTok | $0.50 / MTok |
    | Claude Haiku 5.5 (for prompts over 100,000 tokens) | $0.50 / MTok | $0.625 / MTok | $1 / MTok | $0.05 / MTok | $2.50 / MTok |
    | Claude Haiku 4.5 | $1 / MTok | $1.25 / MTok | $2 / MTok | $0.10 / MTok | $5 / MTok |

    *<sup>1 Cache hits and refreshes on Claude Fable 5.2 are priced at 0.025x the base input price.</sup>*

    ## Cloud platform pricing

    | Model | Base input tokens | 5m cache writes | 1h cache writes | Cache hits and refreshes | Output tokens |
    | :---- | :---- | :---- | :---- | :---- | :---- |
    | Claude Opus 5.5 | $99 / MTok | $99 / MTok | $99 / MTok | $99 / MTok | $99 / MTok |
    """

    @Test func readsTheModelTable() throws {
        let models = try #require(LivePrices.parse(Self.page))
        #expect(models.count == 11)
        #expect(models["claude-opus-5-5"]?.standard == Rates(input: 4, output: 20, cacheRead: 0.2, cacheWrite5m: 5, cacheWrite1h: 8))
        #expect(models["claude-mythos-5-2"]?.standard.input == 8)
        #expect(models["claude-opus-4-1"]?.standard.output == 75)
        #expect(models["claude-sonnet-5"]?.standard.input == 2)
        #expect(models["claude-sonnet-5"]?.standard.output == 10)
    }

    @Test func haikuGetsBothRateCards() throws {
        let haiku = try #require(LivePrices.parse(Self.page)?["claude-haiku-5-5"])
        #expect(haiku.standard == Rates(input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite5m: 0.125, cacheWrite1h: 0.2))
        #expect(haiku.longPrompt == Rates(input: 0.5, output: 2.5, cacheRead: 0.05, cacheWrite5m: 0.625, cacheWrite1h: 1))
        #expect(haiku.longPromptThreshold == 100_000)
    }

    @Test func rejectsPagesThatDontLookRight() {
        #expect(LivePrices.parse("<!doctype html><html><body>Pricing</body></html>") == nil)
        let short = Self.page.split(separator: "\n", omittingEmptySubsequences: false).prefix(9).joined(separator: "\n")
        #expect(LivePrices.parse(short) == nil)
        #expect(LivePrices.parse(Self.page.replacingOccurrences(of: "| $4 / MTok", with: "| $0 / MTok")) == nil)
    }

    static let header = "| Model | Base input tokens | 5m cache writes | 1h cache writes | Cache hits and refreshes | Output tokens |"

    @Test func columnsAreFoundByTheirHeadings() throws {
        // Output moved to the front.
        var page = Self.page.replacingOccurrences(of: Self.header,
            with: "| Model | Output tokens | Base input tokens | 5m cache writes | 1h cache writes | Cache hits and refreshes |")
        page = page.replacingOccurrences(of: "| Claude Opus 5.5 | $4 / MTok | $5 / MTok | $8 / MTok | $0.20 / MTok<sup>2</sup> | $20 / MTok |",
                                         with: "| Claude Opus 5.5 | $20 / MTok | $4 / MTok | $5 / MTok | $8 / MTok | $0.20 / MTok |")
        let rows = page.components(separatedBy: "\n").filter { $0.hasPrefix("| Claude") && !$0.contains("Opus 5.5") }
        for row in rows.prefix(12) {
            var cells = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let output = cells.remove(at: 6)
            cells.insert(output, at: 2)
            page = page.replacingOccurrences(of: row, with: cells.joined(separator: "|"))
        }
        let models = try #require(LivePrices.parse(page))
        #expect(models["claude-opus-5-5"]?.standard == Rates(input: 4, output: 20, cacheRead: 0.2, cacheWrite5m: 5, cacheWrite1h: 8))
    }

    @Test func aMissingColumnRejectsThePage() {
        #expect(LivePrices.parse(Self.page.replacingOccurrences(of: "| Output tokens |", with: "| Tokens out |")) == nil)
    }

    @Test func aSecondRowForTheSameModelRejectsThePage() {
        let extra = "| Claude Opus 5.5 (fast mode) | $8 / MTok | $10 / MTok | $16 / MTok | $0.40 / MTok | $40 / MTok |"
        #expect(LivePrices.parse(Self.page.replacingOccurrences(of: "| Claude Opus 5 |", with: extra + "\n| Claude Opus 5 |")) == nil)
    }

    @Test func implausiblePricesRejectThePage() {
        #expect(LivePrices.parse(Self.page.replacingOccurrences(of: "| $20 / MTok |", with: "| $2 / MTok |")) == nil)
    }

    @Test func aRowItCantReadRejectsThePage() {
        #expect(LivePrices.parse(Self.page.replacingOccurrences(of: "| Claude Opus 5 |", with: "| **Claude Opus 5** |")) == nil)
    }

    @Test func promptTiersMustBeComplete() {
        #expect(LivePrices.parse(Self.page.replacingOccurrences(of: "up to 100,000 tokens", with: "up to 100K tokens")) == nil)
        let oneTier = Self.page.components(separatedBy: "\n").filter { !$0.contains("prompts over") }.joined(separator: "\n")
        #expect(LivePrices.parse(oneTier) == nil)
    }

    @Test func cachedPricesComeFirstAndBuiltInFillsTheRest() throws {
        let dir = try TempDir()
        let paths = ClaudePaths(claudeDir: dir.url)
        var fetched = try #require(LivePrices.parse(Self.page))
        fetched["claude-opus-5-5"]?.standard.input = 3
        try LivePrices.save(fetched, paths: paths, at: .now)
        let table = LivePrices.table(paths)
        #expect(table["claude-opus-5-5"]?.standard.input == 3)
        #expect(table["claude-opus-4-8"]?.standard.input == 5)
    }

    @Test func refreshIsDueOncePerDay() throws {
        let dir = try TempDir()
        let paths = ClaudePaths(claudeDir: dir.url)
        let now = Date.now
        #expect(LivePrices.isDue(paths, now: now))
        try LivePrices.save(try #require(LivePrices.parse(Self.page)), paths: paths, at: now.addingTimeInterval(-3600))
        #expect(!LivePrices.isDue(paths, now: now))
        #expect(LivePrices.isDue(paths, now: now.addingTimeInterval(86_400)))
    }
}
