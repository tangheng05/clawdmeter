import Carbon
import Foundation

enum Shortcut: String, CaseIterable, Identifiable {
    case optionCommandC, controlOptionCommandC, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionCommandC: "⌥⌘C"
        case .controlOptionCommandC: "⌃⌥⌘C"
        case .off: "Off"
        }
    }

    fileprivate var modifiers: UInt32? {
        switch self {
        case .optionCommandC: UInt32(optionKey | cmdKey)
        case .controlOptionCommandC: UInt32(controlKey | optionKey | cmdKey)
        case .off: nil
        }
    }
}

/// A system-wide shortcut via Carbon's hot key API, which needs no Accessibility permission.
@MainActor
final class HotKey {
    static var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private(set) var current: Shortcut?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.action?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(_ shortcut: Shortcut) {
        guard shortcut != current else { return }
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        current = shortcut
        guard let modifiers = shortcut.modifiers else { return }
        let id = EventHotKeyID(signature: OSType(0x434C_4D54), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_C), modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}
