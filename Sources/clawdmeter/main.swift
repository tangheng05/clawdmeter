import ClawdmeterCore
import Foundation

// A previous statusline command that exits without reading its input must not kill us.
signal(SIGPIPE, SIG_IGN)

let args = CommandLine.arguments
let paths = ClaudePaths()
var input: Data { FileHandle.standardInput.readDataToEndOfFile() }

func runShell(_ command: String, stdin: Data) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let inPipe = Pipe(), outPipe = Pipe()
    process.standardInput = inPipe
    process.standardOutput = outPipe
    guard (try? process.run()) != nil else { return nil }
    DispatchQueue.global().async {
        try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
        try? inPipe.fileHandleForWriting.close()
    }
    let output = outPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: output, as: UTF8.self)
}

/// The status line repeats old numbers, so ask Anthropic; falls back to local data when offline.
func fetchLimits(account: String?) -> RateLimits? {
    final class Box: @unchecked Sendable { var limits: RateLimits? }
    let box = Box(), done = DispatchSemaphore(value: 0)
    Task.detached {
        if case .limits(let limits) = await UsageAPI.fetch(paths: paths, account: account) { box.limits = limits }
        done.signal()
    }
    done.wait()
    return box.limits
}

func printJSON(_ value: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(value) {
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

switch args.dropFirst().first {
case "hook" where args.count >= 3:
    HookHandler.handle(event: args[2], input: input, paths: paths, parentPID: getppid())
case "statusline":
    let line = StatuslineHandler.handle(input: input, paths: paths, runPrevious: runShell)
    FileHandle.standardOutput.write(Data(line.utf8))
case "uninstall":
    // Used by `brew uninstall --zap`: removes the hooks and status line before the files go.
    do {
        try Installer(paths: paths, helperSource: paths.helperPath).uninstall()
        AccountSwitcher(paths: paths).forgetAll()
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
case "limits":
    let snapshot = Account.read(paths)
    printJSON(LimitsReport(limits: RateLimits.best(paths: paths, fetched: fetchLimits(account: snapshot.account)),
                           snapshot: snapshot))
case "spend":
    printJSON(SpendIndex(paths: paths).refresh())
case "accounts":
    struct Row: Encodable { let key: String, email: String?, plan: String?, organization: String?, active: Bool }
    func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }
    let switcher = AccountSwitcher(paths: paths)
    guard switcher.isSupported else { fail("Sign in to Claude Code with a claude.ai account first.") }
    switch args.dropFirst(2).first {
    case nil:
        let active = switcher.activeKey()
        printJSON(switcher.saved().map {
            Row(key: $0.key, email: $0.email, plan: $0.plan, organization: $0.organization, active: $0.key == active)
        })
    case "save":
        do { try switcher.saveActive() } catch { fail(error.localizedDescription) }
    case "switch" where args.count >= 4:
        let wanted = args[3]
        let matches = switcher.saved().filter { $0.key == wanted || $0.email == wanted }
        guard matches.count == 1 else {
            fail(matches.isEmpty ? "No saved account matches \(wanted)." : "Several accounts match; use the key from `clawdmeter accounts`.")
        }
        let change: AccountChange?
        do { change = try switcher.switchTo(matches[0].key) } catch { fail(error.localizedDescription) }
        guard let change else { break }
        FileHandle.standardError.write(Data("Switched. Watching for a minute in case a running session writes the old login back…\n".utf8))
        let reapplied = switcher.guardSwitch(change)
        if reapplied > 0 { FileHandle.standardError.write(Data("Put it back \(reapplied) time(s) after a renewal.\n".utf8)) }
    default:
        fail("usage: clawdmeter accounts [save | switch <email or key>]")
    }
default:
    FileHandle.standardError.write(Data("usage: clawdmeter limits | spend | accounts | hook <event> | statusline | uninstall\n".utf8))
}
exit(0)
