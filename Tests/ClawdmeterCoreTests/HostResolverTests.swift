import Foundation
import Testing
@testable import ClawdmeterCore

@Suite struct HostResolverTests {
    func node(_ pid: Int32, _ name: String, _ path: String, tty: String? = "/dev/ttys004") -> ProcessNode {
        ProcessNode(pid: pid, ppid: pid - 1, name: name, path: path, tty: tty)
    }

    let claude = ProcessNode(pid: 100, ppid: 99, name: "claude", path: "/Users/me/.local/bin/claude", tty: "/dev/ttys004")
    let zsh = ProcessNode(pid: 99, ppid: 98, name: "zsh", path: "/bin/zsh", tty: "/dev/ttys004")

    @Test func terminalTab() {
        let chain = [claude, zsh, node(98, "login", "/usr/bin/login"),
                     node(97, "Terminal", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", tty: nil)]
        #expect(HostResolver.plan(chain: chain, cwd: "/w") ==
                .terminalTab(app: "/System/Applications/Utilities/Terminal.app", appPID: 97, tty: "/dev/ttys004"))
    }

    @Test func itermSession() {
        let chain = [claude, zsh, node(97, "iTerm2", "/Applications/iTerm.app/Contents/MacOS/iTerm2", tty: nil)]
        #expect(HostResolver.plan(chain: chain, cwd: "/w") ==
                .itermSession(app: "/Applications/iTerm.app", appPID: 97, tty: "/dev/ttys004"))
    }

    @Test func editorHelperResolvesToOuterApp() {
        let helper = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        let chain = [claude, zsh, node(97, "Code Helper", helper, tty: nil),
                     node(96, "Electron", "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", tty: nil)]
        #expect(HostResolver.plan(chain: chain, cwd: "/w/api") ==
                .openFolder(app: "/Applications/Visual Studio Code.app", appPID: 96, folder: "/w/api"))
    }

    @Test func tmuxServer() {
        let chain = [claude, zsh, node(98, "tmux", "/opt/homebrew/bin/tmux", tty: nil), node(1, "launchd", "/sbin/launchd", tty: nil)]
        #expect(HostResolver.plan(chain: chain, cwd: "/w") == .tmux(binary: "/opt/homebrew/bin/tmux", paneTTY: "/dev/ttys004"))
    }

    @Test func otherAppIsActivated() {
        let chain = [claude, zsh, node(97, "ghostty", "/Applications/Ghostty.app/Contents/MacOS/ghostty", tty: nil)]
        #expect(HostResolver.plan(chain: chain, cwd: "/w") == .activate(app: "/Applications/Ghostty.app", appPID: 97))
    }

    @Test func noHostFound() {
        #expect(HostResolver.plan(chain: [claude, node(1, "launchd", "/sbin/launchd", tty: nil)], cwd: "/w") == nil)
    }

    @Test func liveAncestorsIncludeSelf() {
        let chain = ProcessTree.ancestors(of: getpid())
        #expect(chain.first?.pid == getpid())
        #expect(chain.count > 1)
    }
}
