import Foundation
import Testing
@testable import ClawdmeterCore

@Suite struct UpdateTests {
    @Test func versionOrdering() {
        #expect(UpdateChecker.isNewer("v0.3.0", than: "0.2.5"))
        #expect(UpdateChecker.isNewer("0.2.10", than: "0.2.9"))
        #expect(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        #expect(!UpdateChecker.isNewer("0.2.5", than: "0.2.5"))
        #expect(!UpdateChecker.isNewer("0.2", than: "0.2.0"))
        #expect(!UpdateChecker.isNewer("garbage", than: "0.2.5"))
    }

    let release = """
    {"tag_name":"v0.3.0","html_url":"https://github.com/o/r/releases/tag/v0.3.0","assets":[
     {"name":"Clawdmeter.zip","browser_download_url":"https://example.com/Clawdmeter.zip"},
     {"name":"Clawdmeter.zip.sha256","browser_download_url":"https://example.com/Clawdmeter.zip.sha256"}]}
    """

    @Test func parsesRelease() throws {
        let info = try #require(UpdateChecker.parseLatestRelease(Data(release.utf8)))
        #expect(info.version == "0.3.0")
        #expect(info.zipURL.absoluteString == "https://example.com/Clawdmeter.zip")
        #expect(info.checksumURL?.absoluteString == "https://example.com/Clawdmeter.zip.sha256")
    }

    @Test func releaseWithoutChecksumOrZip() {
        let noSha = #"{"tag_name":"v1","html_url":"https://x","assets":[{"name":"Clawdmeter.zip","browser_download_url":"https://x/z"}]}"#
        #expect(UpdateChecker.parseLatestRelease(Data(noSha.utf8))?.checksumURL == nil)
        #expect(UpdateChecker.parseLatestRelease(Data(#"{"tag_name":"v1","assets":[]}"#.utf8)) == nil)
        #expect(UpdateChecker.parseLatestRelease(Data("{".utf8)) == nil)
    }

    @Test func checksumVerification() {
        let zip = Data("hello".utf8)
        let good = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824  Clawdmeter.zip\n"
        #expect(UpdateChecker.verifyChecksum(zip, checksumFile: good))
        #expect(!UpdateChecker.verifyChecksum(Data("hellO".utf8), checksumFile: good))
        #expect(!UpdateChecker.verifyChecksum(zip, checksumFile: ""))
    }
}
