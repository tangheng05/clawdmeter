import Foundation

/// Whether anything is capturing the screen, like a Zoom or Meet share or a recording. macOS has
/// no public API for this, so the window server's own flag is looked up at runtime; if it ever
/// goes away, the feature reports itself unavailable instead of crashing.
@MainActor
enum ScreenShare {
    private typealias IsWatcherPresent = @convention(c) () -> Bool
    private typealias Callback = @convention(c) (UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void
    private typealias RegisterNotifyProc = @convention(c) (Callback, UInt32, UnsafeMutableRawPointer?) -> Int32

    private static let isWatcherPresent = symbol("SLSIsScreenWatcherPresent", "CGSIsScreenWatcherPresent")
        .map { unsafeBitCast($0, to: IsWatcherPresent.self) }
    private static let registerNotifyProc = symbol("SLSRegisterNotifyProc", "CGSRegisterNotifyProc")
        .map { unsafeBitCast($0, to: RegisterNotifyProc.self) }

    private static var onChange: (() -> Void)?
    private static var registered = false

    static var isAvailable: Bool { isWatcherPresent != nil && registerNotifyProc != nil }
    static var isActive: Bool { isWatcherPresent?() ?? false }

    /// Calls `handler` when a capture starts or stops. It's driven by window server events, so it
    /// costs nothing in between.
    static func observe(_ handler: @escaping () -> Void) {
        onChange = handler
        guard !registered, let registerNotifyProc else { return }
        registered = true
        let callback: Callback = { _, _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { ScreenShare.onChange?() } }
        }
        // A screen watcher attaching and detaching; the window server offers no way to unregister.
        _ = registerNotifyProc(callback, 1502, nil)
        _ = registerNotifyProc(callback, 1503, nil)
    }

    private static func symbol(_ names: String...) -> UnsafeMutableRawPointer? {
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        return names.lazy.compactMap { dlsym(everywhere, $0) }.first
    }
}
