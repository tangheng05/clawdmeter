import CryptoKit
import Foundation

public struct ReleaseInfo: Equatable, Sendable {
    public let version: String
    public let zipURL: URL
    public let checksumURL: URL?
    public let pageURL: URL?
}

public enum UpdateChecker {
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/tangheng05/clawdmeter/releases/latest")!

    public static func parseLatestRelease(_ data: Data) -> ReleaseInfo? {
        struct Raw: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let html_url: URL?
            let assets: [Asset]
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data),
              let zip = raw.assets.first(where: { $0.name == "Clawdmeter.zip" }) else { return nil }
        let version = raw.tag_name.hasPrefix("v") ? String(raw.tag_name.dropFirst()) : raw.tag_name
        return ReleaseInfo(version: version, zipURL: zip.browser_download_url,
                           checksumURL: raw.assets.first { $0.name == "Clawdmeter.zip.sha256" }?.browser_download_url,
                           pageURL: raw.html_url)
    }

    public static func isNewer(_ remote: String, than local: String) -> Bool {
        guard let a = numbers(remote), let b = numbers(local) else { return false }
        let count = max(a.count, b.count)
        let padded = { (v: [Int]) in v + Array(repeating: 0, count: count - v.count) }
        return padded(a).lexicographicallyPrecedes(padded(b)) == false && padded(a) != padded(b)
    }

    /// `checksumFile` is `shasum -a 256` output: the hex digest, then the file name.
    public static func verifyChecksum(_ data: Data, checksumFile: String) -> Bool {
        guard let expected = checksumFile.split(whereSeparator: \.isWhitespace).first?.lowercased(),
              expected.count == 64 else { return false }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual == expected
    }

    private static func numbers(_ version: String) -> [Int]? {
        let trimmed = version.hasPrefix("v") ? version.dropFirst() : Substring(version)
        let parts = trimmed.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }
}
