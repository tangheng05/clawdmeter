import Foundation

/// Without a terminal the CLI never asks for a pasted code; it waits for the browser to hand the login back.
enum LoginRunner {
    enum Outcome: Sendable {
        case signedIn
        case failed(String)
    }

    static let timeout: TimeInterval = 180

    static func signIn(email: String?) async -> Outcome {
        guard let claude = await Task.detached(operation: findClaude).value else {
            return .failed("Couldn't find the claude command. Run `claude auth login` in a terminal instead.")
        }
        var arguments = ["auth", "login"]
        if let email { arguments += ["--email", email] }
        return await withCheckedContinuation { continuation in
            run(claude, arguments) { continuation.resume(returning: $0) }
        }
    }

    private static func run(_ claude: URL, _ arguments: [String], done: @escaping @Sendable (Outcome) -> Void) {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var finished = false
            var timedOut = false
        }
        let state = State()
        let process = Process()
        process.executableURL = claude
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        @Sendable func finish(_ outcome: Outcome) {
            let first = state.lock.withLock {
                defer { state.finished = true }
                return !state.finished
            }
            if first { done(outcome) }
        }
        process.terminationHandler = { process in
            if state.lock.withLock({ state.timedOut }) {
                return finish(.failed("The sign-in timed out. Try again when you're ready."))
            }
            finish(process.terminationStatus == 0 ? .signedIn
                   : .failed("The sign-in didn't finish. You can also run `claude auth login` in a terminal."))
        }
        do {
            try process.run()
        } catch {
            return finish(.failed("Couldn't start the claude command."))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            state.lock.withLock { state.timedOut = true }
            process.terminate()
        }
    }

    /// Apps opened from Finder don't get the shell's PATH, so look where Claude Code installs first.
    @Sendable private static func findClaude() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude"]
        if let path = candidates.first(where: FileManager.default.isExecutableFile) { return URL(fileURLWithPath: path) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // A login shell's profile may print first; the path is the last line.
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        process.waitUntilExit()
        return FileManager.default.isExecutableFile(atPath: output) ? URL(fileURLWithPath: output) : nil
    }
}
