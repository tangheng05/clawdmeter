import Darwin
import Foundation

public struct ProcessNode: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let name: String
    public let path: String
    public let tty: String?

    public init(pid: Int32, ppid: Int32, name: String, path: String, tty: String?) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.path = path
        self.tty = tty
    }
}

public enum ProcessTree {
    public static func node(_ pid: Int32) -> ProcessNode? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }

        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let path = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0
            ? String(decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        let dev = info.kp_eproc.e_tdev
        let tty = dev == -1 ? nil : devname(dev, S_IFCHR).map { "/dev/" + String(cString: $0) }
        return ProcessNode(pid: pid, ppid: info.kp_eproc.e_ppid, name: name, path: path, tty: tty)
    }

    public static func startTime(_ pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    /// The process itself first, then each parent up to launchd.
    public static func ancestors(of pid: Int32) -> [ProcessNode] {
        var chain: [ProcessNode] = []
        var current = pid
        while current > 1, chain.count < 64, let node = node(current) {
            chain.append(node)
            current = node.ppid
        }
        return chain
    }
}

public enum FocusPlan: Equatable, Sendable {
    case terminalTab(app: String, appPID: Int32, tty: String)
    case itermSession(app: String, appPID: Int32, tty: String)
    case openFolder(app: String, appPID: Int32, folder: String)
    case tmux(binary: String, paneTTY: String)
    case activate(app: String, appPID: Int32)
}

public enum HostResolver {
    static let editors = ["Visual Studio Code", "Cursor", "Windsurf", "Zed", "VSCodium"]

    public static func plan(chain: [ProcessNode], cwd: String) -> FocusPlan? {
        let tty = chain.first?.tty
        for node in chain.dropFirst() {
            if node.name == "tmux", let tty { return .tmux(binary: node.path, paneTTY: tty) }
            guard let app = outerApp(node.path) else { continue }
            let appName = URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent
            // Helpers live inside the app; the main process further up has the activatable PID.
            let appPID = chain.last { outerApp($0.path) == app }?.pid ?? node.pid
            switch appName {
            case "Terminal" where tty != nil: return .terminalTab(app: app, appPID: appPID, tty: tty!)
            case "iTerm" where tty != nil: return .itermSession(app: app, appPID: appPID, tty: tty!)
            case _ where editors.contains(appName): return .openFolder(app: app, appPID: appPID, folder: cwd)
            default: return .activate(app: app, appPID: appPID)
            }
        }
        return nil
    }

    static func outerApp(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }
}
