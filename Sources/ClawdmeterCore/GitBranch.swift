import Foundation

public enum GitBranch {
    /// Reads `.git/HEAD` directly (walking up from `path`), so no `git` process is spawned.
    public static func current(in path: String) -> String? {
        var dir = URL(fileURLWithPath: path).standardizedFileURL
        while dir.path != "/" {
            let dotGit = dir.appending(path: ".git")
            if let head = headFile(for: dotGit), let text = try? String(contentsOf: head, encoding: .utf8) {
                let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("ref: refs/heads/") { return String(line.dropFirst("ref: refs/heads/".count)) }
                return line.isEmpty ? nil : String(line.prefix(7))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    private static func headFile(for dotGit: URL) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return dotGit.appending(path: "HEAD") }
        // Worktrees and submodules use a `.git` file pointing at the real git dir.
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first, line.hasPrefix("gitdir: ") else { return nil }
        let target = String(line.dropFirst("gitdir: ".count))
        let base = target.hasPrefix("/") ? URL(fileURLWithPath: target)
                                         : dotGit.deletingLastPathComponent().appending(path: target)
        return base.appending(path: "HEAD")
    }
}
