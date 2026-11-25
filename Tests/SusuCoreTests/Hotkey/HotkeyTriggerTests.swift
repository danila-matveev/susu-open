import Testing
@testable import SusuCore

/// A chord trigger (Ctrl+Space) must not fire on the bare key (Codex review 25.11.2026).
@Suite struct HotkeyTriggerTests {
    @Test func chordNeedsExactlyItsModifiers() throws {
        let ctrlSpace = try #require(HotkeyTrigger.key(49, modifiers: 0x40000))
        #expect(ctrlSpace.matchesKeyDown(keyCode: 49, flags: 0x40000))
        #expect(!ctrlSpace.matchesKeyDown(keyCode: 49, flags: 0))
        #expect(!ctrlSpace.matchesKeyDown(keyCode: 49, flags: 0x40000 | 0x100000))
        #expect(!ctrlSpace.matchesKeyDown(keyCode: 50, flags: 0x40000))
    }

    @Test func bareTypingKeyIsRejectedButFunctionKeyIsAllowed() throws {
        #expect(HotkeyTrigger.key(49, modifiers: 0) == nil)
        let f18 = try #require(HotkeyTrigger.key(79, modifiers: 0))
        #expect(f18 == .f18)
        #expect(f18.matchesKeyDown(keyCode: 79, flags: 0))
        // Caps Lock and other non-modifier flag bits do not matter.
        #expect(f18.matchesKeyDown(keyCode: 79, flags: 0x10000))
    }

    @Test func modifierTriggerNeverMatchesKeyDown() {
        #expect(!HotkeyTrigger.leftControl.matchesKeyDown(keyCode: 59, flags: 0x40000))
    }
}
