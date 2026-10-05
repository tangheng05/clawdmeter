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
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
case "limits":
    printJSON(LimitsReport(limits: RateLimits.best(paths: paths), snapshot: Account.read(paths)))
case "spend":
    printJSON(SpendIndex(paths: paths).refresh())
default:
    FileHandle.standardError.write(Data("usage: clawdmeter limits | spend | hook <event> | statusline | uninstall\n".utf8))
}
exit(0)
