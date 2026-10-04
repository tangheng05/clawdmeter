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

@Suite struct PolishTests {
    @Test func headlinePicksHigherLimit() {
        let limits = RateLimits(fiveHour: LimitWindow(usedPercentage: 7, resetsAt: nil),
                                sevenDay: LimitWindow(usedPercentage: 86, resetsAt: nil), updatedAt: .now)
        #expect(limits.headline?.label == "wk")
        #expect(limits.headline?.window.usedPercentage == 86)
        let early = RateLimits(fiveHour: LimitWindow(usedPercentage: 40, resetsAt: nil), sevenDay: nil, updatedAt: .now)
        #expect(early.headline?.label == "5h")
    }

    @Test func gitBranchFromHead() throws {
        let dir = try TempDir()
        try dir.write("ref: refs/heads/feature/x\n", to: "repo/.git/HEAD")
        try FileManager.default.createDirectory(at: dir.url.appending(path: "repo/sub"), withIntermediateDirectories: true)
        #expect(GitBranch.current(in: dir.url.appending(path: "repo/sub").path) == "feature/x")
    }

    @Test func gitBranchFromWorktreeAndDetached() throws {
        let dir = try TempDir()
        try dir.write("ref: refs/heads/wt\n", to: "main/.git/worktrees/a/HEAD")
        try dir.write("gitdir: \(dir.url.path)/main/.git/worktrees/a\n", to: "wt/.git")
        #expect(GitBranch.current(in: dir.url.appending(path: "wt").path) == "wt")
        try dir.write("0123456789abcdef0123\n", to: "det/.git/HEAD")
        #expect(GitBranch.current(in: dir.url.appending(path: "det").path) == "0123456")
        #expect(GitBranch.current(in: dir.url.path) == nil)
    }
}
