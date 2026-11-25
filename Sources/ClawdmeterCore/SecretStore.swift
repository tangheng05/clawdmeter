import Foundation

public protocol SecretStore: Sendable {
    func read(service: String, account: String) -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String)
}

/// Through `security`, so items never prompt even after an update changes the app's signature.
public struct SecurityCLI: SecretStore {
    static let tool = URL(fileURLWithPath: "/usr/bin/security")
    /// `security -i` drops longer lines (measured: 3 KB works, 5 KB fails).
    static let lineLimit = 4000

    public init() {}

    public func read(service: String, account: String) -> Data? {
        guard let (status, output) = Self.run(["find-generic-password", "-a", account, "-s", service, "-w"]),
              status == 0 else { return nil }
        var text = String(decoding: output, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        // `-w` prints a value that isn't plain ASCII as hex.
        if !text.hasPrefix("{"), let decoded = Data(hex: text) { return decoded }
        return Data(text.utf8)
    }

    public func write(_ data: Data, service: String, account: String) throws {
        // Never as arguments: other processes can read those.
        guard let line = Self.command(for: data, service: service, account: account) else {
            throw SwitchError.writeFailed("Claude Code's login is too large for Clawdmeter to switch.")
        }
        _ = Self.run(["-i"], input: Data(line.utf8))
        guard read(service: service, account: account) == data else {
            throw SwitchError.writeFailed("The Keychain didn't accept the change.")
        }
    }

    /// Quoted when it can be, which fits twice as much as hex. Nil when neither fits on one line.
    static func command(for data: Data, service: String, account: String) -> String? {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let prefix = "add-generic-password -U -a \(quoted(account)) -s \(quoted(service))"
        var line: String
        if let text = String(data: data, encoding: .utf8), !text.unicodeScalars.contains(where: { $0.value < 0x20 }) {
            line = "\(prefix) -w \(quoted(text))\n"
        } else {
            line = "\(prefix) -X \(data.map { String(format: "%02x", $0) }.joined())\n"
        }
        return line.utf8.count < lineLimit ? line : nil
    }

    public func delete(service: String, account: String) {
        _ = Self.run(["delete-generic-password", "-a", account, "-s", service])
    }

    private static func run(_ arguments: [String], input: Data? = nil) -> (Int32, Data)? {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let output = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        guard (try? process.run()) != nil else { return nil }
        if let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2), !hex.isEmpty else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
