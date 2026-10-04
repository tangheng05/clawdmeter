import Foundation

/// How full each session's context window is, keyed by session id, from the status line.
public enum ContextReader {
    public static func read(_ paths: ClaudePaths, now: Date = .now) -> [String: Double] {
        let fm = FileManager.default
        var usage: [String: Double] = [:]
        for url in jsonFiles(in: paths.contextDir) {
            if let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
               now.timeIntervalSince(modified) > 86_400 {
                try? fm.removeItem(at: url)
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let used = (json["used"] as? NSNumber)?.doubleValue else { continue }
            usage[url.deletingPathExtension().lastPathComponent] = used
        }
        return usage
    }
}
