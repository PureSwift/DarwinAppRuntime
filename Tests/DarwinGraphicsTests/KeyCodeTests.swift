import DynamicGraphics
import Testing
@testable import DarwinGraphics

@Suite("Key codes")
struct KeyCodeTests {

    @Test func macKeysBecomeHIDUsages() {
        #expect(KeyCodes.hidUsage(macKeyCode: 0x0D) == KeyCode.w.rawValue)
        #expect(KeyCodes.hidUsage(macKeyCode: 0x00) == KeyCode.a.rawValue)
        #expect(KeyCodes.hidUsage(macKeyCode: 0x01) == KeyCode.s.rawValue)
        #expect(KeyCodes.hidUsage(macKeyCode: 0x02) == KeyCode.d.rawValue)
        #expect(KeyCodes.hidUsage(macKeyCode: 0x31) == KeyCode.space.rawValue)
        #expect(KeyCodes.hidUsage(macKeyCode: 0x24) == KeyCode.return.rawValue)
        #expect(KeyCodes.hidUsage(macKeyCode: 0x35) == KeyCode.escape.rawValue)
        #expect(KeyCodes.hidUsage(macKeyCode: 0x33) == KeyCode.backspace.rawValue)
        #expect(KeyCodes.hidUsage(macKeyCode: 0x75) == KeyCode.delete.rawValue)
        #expect(KeyCodes.hidUsage(macKeyCode: 0x7E) == KeyCode.up.rawValue)
        #expect(KeyCodes.hidUsage(macKeyCode: 0x7B) == KeyCode.left.rawValue)
        #expect(KeyCodes.hidUsage(macKeyCode: 0x1D) == KeyCode.digit(0).rawValue)
        #expect(KeyCodes.hidUsage(macKeyCode: 0x12) == KeyCode.digit(1).rawValue)
        #expect(KeyCodes.hidUsage(macKeyCode: 0x7A) == KeyCode.function(1).rawValue)
        #expect(KeyCodes.hidUsage(macKeyCode: 0x6F) == KeyCode.function(12).rawValue)
        #expect(KeyCodes.hidUsage(macKeyCode: 0x38) == KeyCode.leftShift.rawValue)
        #expect(KeyCodes.hidUsage(macKeyCode: 0x36) == KeyCode.rightMeta.rawValue)
        #expect(KeyCodes.hidUsage(macKeyCode: 0x3F) == nil, "Fn has no usage")
    }

    @Test func everyKeyHasItsOwnUsage() {
        let usages = Array(KeyCodes.macKeys.values)
        #expect(Set(usages).count == usages.count)
        #expect(usages.allSatisfy { (0x04...0xE7).contains($0) })
        #expect(KeyCodes.macModifierMasks.keys.allSatisfy { KeyCodes.macKeys[$0] != nil })
    }

    @Test func modifiers() {
        #expect(KeyCodes.modifiers(flags: 0) == [])
        #expect(KeyCodes.modifiers(flags: 1 << 17) == .shift)
        #expect(KeyCodes.modifiers(flags: 1 << 18 | 1 << 19) == [.control, .alt])
        #expect(KeyCodes.modifiers(flags: 1 << 20 | 1 << 16) == .meta, "Caps Lock isn't a modifier here")
    }
}
