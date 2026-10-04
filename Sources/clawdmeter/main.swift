import ClawdmeterCore
import Foundation

let args = CommandLine.arguments
let paths = ClaudePaths()
let input = FileHandle.standardInput.readDataToEndOfFile()

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

switch args.dropFirst().first {
case "hook" where args.count >= 3:
    HookHandler.handle(event: args[2], input: input, paths: paths, parentPID: getppid())
case "statusline":
    let line = StatuslineHandler.handle(input: input, paths: paths, runPrevious: runShell)
    FileHandle.standardOutput.write(Data(line.utf8))
default:
    FileHandle.standardError.write(Data("usage: clawdmeter hook <event> | clawdmeter statusline\n".utf8))
}
exit(0)
