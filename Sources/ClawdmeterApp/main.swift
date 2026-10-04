import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        statusItem = StatusItemController(model: model)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
