import Foundation

/// A global keyboard shortcut, stored as the key code plus modifier flags.
public struct KeyCombo: Codable, Equatable, Sendable {
    public let keyCode: UInt32
    /// The key's label at the time it was recorded, e.g. "c".
    public let key: String
    public let command: Bool
    public let option: Bool
    public let control: Bool
    public let shift: Bool

    /// ⌃⌥⌘C: ⌥⌘C alone is Finder's "Copy as Pathname".
    public static let `default` = KeyCombo(keyCode: 8, key: "c", command: true, option: true, control: true, shift: false)

    public init(keyCode: UInt32, key: String, command: Bool, option: Bool, control: Bool, shift: Bool) {
        self.keyCode = keyCode
        self.key = key
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    /// Shift alone would clash with ordinary typing.
    public var isValid: Bool { !key.isEmpty && (command || option || control) }

    public var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key.uppercased()
    }

    /// Carbon's `cmdKey`, `shiftKey`, `optionKey` and `controlKey` masks.
    public var carbonModifiers: UInt32 {
        (command ? 0x100 : 0) | (shift ? 0x200 : 0) | (option ? 0x800 : 0) | (control ? 0x1000 : 0)
    }
}
