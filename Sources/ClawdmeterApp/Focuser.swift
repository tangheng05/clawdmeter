import AppKit
import ClawdmeterCore

/// Brings the terminal tab or editor window running a session to the front.
@MainActor
enum Focuser {
    static func plan(for session: Session) -> FocusPlan? {
        HostResolver.plan(chain: ProcessTree.ancestors(of: session.pid), cwd: session.cwd)
    }

    /// The app hosting the session, used to skip notifications you're already looking at.
    static func hostPID(for session: Session) -> Int32? {
        switch plan(for: session) {
        case .terminalTab(_, let pid, _), .itermSession(_, let pid, _), .openFolder(_, let pid, _), .activate(_, let pid):
            pid
        case .tmux, nil:
            nil
        }
    }

    static func focus(_ session: Session) {
        if let plan = plan(for: session) {
            execute(plan)
        } else if !session.cwd.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)])
        } else {
            NSSound.beep()
        }
    }

    private static func execute(_ plan: FocusPlan) {
        switch plan {
        case .terminalTab(_, let pid, let tty):
            if !runScript(terminalScript(tty: tty)) { activate(pid) }
        case .itermSession(_, let pid, let tty):
            if !runScript(itermScript(tty: tty)) { activate(pid) }
        case .openFolder(let app, _, let folder):
            NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: URL(fileURLWithPath: app),
                                    configuration: NSWorkspace.OpenConfiguration())
        case .tmux(let binary, let paneTTY):
            focusTmux(binary: binary, paneTTY: paneTTY)
        case .activate(_, let pid):
            activate(pid)
        }
    }

    private static func activate(_ pid: Int32) {
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    private static func focusTmux(binary: String, paneTTY: String) {
        let panes = run(binary, ["list-panes", "-a", "-F", "#{pane_tty} #{session_name}:#{window_index}.#{pane_index}"])
        guard let target = panes.split(separator: "\n").first(where: { $0.hasPrefix(paneTTY + " ") })?
            .split(separator: " ", maxSplits: 1).last.map(String.init) else { return }
        let client = run(binary, ["list-clients", "-F", "#{client_tty} #{client_pid}"])
            .split(separator: "\n").first?.split(separator: " ")
        if let clientTTY = client?.first {
            _ = run(binary, ["switch-client", "-c", String(clientTTY), "-t", target])
        }
        _ = run(binary, ["select-window", "-t", target])
        _ = run(binary, ["select-pane", "-t", target])
        // Then bring forward the terminal the tmux client is attached in.
        if let pidText = client?.last, let pid = Int32(pidText),
           let hostPlan = HostResolver.plan(chain: ProcessTree.ancestors(of: pid), cwd: "") {
            execute(hostPlan)
        }
    }

    private static func run(_ binary: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func runScript(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }

    private static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                    end if
                end repeat
            end repeat
            activate
        end tell
        """
    }

    private static func itermScript(tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            select t
                            select s
                        end if
                    end repeat
                end repeat
            end repeat
            activate
        end tell
        """
    }
}
