import Foundation
import Testing
@testable import ClawdmeterCore

@Suite struct ModelsTests {
    @Test func stateOrderingIsByPriority() {
        #expect(SessionState.waiting > SessionState.working)
        #expect(SessionState.working > SessionState.idle)
    }

    @Test func displayNameFallsBackToFolder() {
        let s = Session(id: "a", pid: 1, cwd: "/Users/me/code/api", name: nil, state: .idle, since: .now)
        #expect(s.displayName == "api")
        let named = Session(id: "a", pid: 1, cwd: "/Users/me/code/api", name: "Refactor", state: .idle, since: .now)
        #expect(named.displayName == "Refactor")
    }

    @Test func pathsResolveUnderRoot() {
        let paths = ClaudePaths(claudeDir: URL(fileURLWithPath: "/tmp/x"))
        #expect(paths.sessionsDir.path == "/tmp/x/sessions")
        #expect(paths.hooksDir.path == "/tmp/x/clawdmeter/hooks")
        #expect(paths.limitsFile.path == "/tmp/x/clawdmeter/limits.json")
        #expect(paths.helperPath.path == "/tmp/x/clawdmeter/bin/clawdmeter")
        #expect(paths.settingsFile.path == "/tmp/x/settings.json")
    }

    @Test func atomicWriteCreatesParentDirs() throws {
        let dir = try TempDir()
        let file = dir.url.appending(path: "a/b/c.json")
        try writeAtomically(Data("hi".utf8), to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "hi")
    }
}

struct TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "clawdmeter-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    var paths: ClaudePaths { ClaudePaths(claudeDir: url) }

    func write(_ text: String, to relative: String) throws {
        let file = url.appending(path: relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
}
