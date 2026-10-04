import Foundation
import Testing
@testable import ClawdmeterCore

@Suite struct KeyComboTests {
    @Test func displayUsesMacModifierOrder() {
        let combo = KeyCombo(keyCode: 8, key: "c", command: true, option: true, control: true, shift: true)
        #expect(combo.display == "⌃⌥⇧⌘C")
        #expect(KeyCombo.default.display == "⌥⌘C")
    }

    @Test func needsARealModifier() {
        #expect(!KeyCombo(keyCode: 8, key: "c", command: false, option: false, control: false, shift: true).isValid)
        #expect(!KeyCombo(keyCode: 8, key: "", command: true, option: false, control: false, shift: false).isValid)
        #expect(KeyCombo(keyCode: 8, key: "c", command: false, option: false, control: true, shift: false).isValid)
    }

    @Test func carbonModifiers() {
        // cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000
        #expect(KeyCombo.default.carbonModifiers == 0x900)
        #expect(KeyCombo(keyCode: 1, key: "s", command: true, option: false, control: true, shift: true).carbonModifiers == 0x1300)
    }

    @Test func roundTripsAsJSON() throws {
        let data = try JSONEncoder().encode(KeyCombo.default)
        #expect(try JSONDecoder().decode(KeyCombo.self, from: data) == KeyCombo.default)
    }
}
