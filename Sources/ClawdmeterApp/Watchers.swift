import CoreServices
import Foundation

/// FSEvents on a few directories; fires `onChange` on the main queue, coalesced by `latency`.
@MainActor
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(directories: [URL], latency: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        self.onChange = onChange
        for dir in directories {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, callback, &context, directories.map(\.path) as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

/// Kernel process-exit notifications, so dead sessions vanish without polling.
@MainActor
final class ProcessWatcher {
    private var sources: [Int32: DispatchSourceProcess] = [:]
    private let onExit: () -> Void

    init(onExit: @escaping () -> Void) {
        self.onExit = onExit
    }

    func watch(_ pids: Set<Int32>) {
        for (pid, source) in sources where !pids.contains(pid) {
            source.cancel()
            sources[pid] = nil
        }
        for pid in pids where sources[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.onExit() }
            }
            source.resume()
            sources[pid] = source
        }
    }
}

func isProcessAlive(_ pid: Int32) -> Bool {
    pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
}
