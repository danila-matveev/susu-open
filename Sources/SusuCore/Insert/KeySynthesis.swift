#if os(macOS)
import AppKit
import Carbon.HIToolbox

/// Posts real key events. Not used in unit tests (the Inserter takes closures instead).
public enum KeySynthesis {
    /// Key code that types "v" on the current ASCII-capable layout (Dvorak, Colemak, ...).
    /// Cmd shortcuts follow that layout even when a Cyrillic layout is active. Falls back to ANSI 9.
    public static func keyCodeForV() -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return fallback }
        let layoutData = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return fallback }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        for code in 0..<128 {
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeys, chars.count, &length, &chars)
            if status == noErr, length == 1, chars[0] == UniChar(UInt8(ascii: "v")) {
                return CGKeyCode(code)
            }
        }
        return fallback
    }

    public static func pressCommandV() {
        post(key: keyCodeForV(), flags: .maskCommand)
    }

    public static func pressReturn() {
        post(key: CGKeyCode(kVK_Return), flags: [])
    }

    private static func post(key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
#endif
