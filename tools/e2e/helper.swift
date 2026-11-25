// E2E helper: system key presses (CGEvent) and reading the focused text field (Accessibility).
// Built by tools/e2e/selftest into build/e2e-helper. Needs Accessibility for the app that runs it (Terminal / Claude).
// usage: e2e-helper trusted | is-trusted | key-down <keycode> | key-up <keycode> | field-text <bundle-id> | window-count <pid>
import AppKit
import ApplicationServices

func die(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1) }

let modifierFlags: [CGKeyCode: CGEventFlags] = [59: .maskControl, 62: .maskControl, 58: .maskAlternate, 61: .maskAlternate,
                                                55: .maskCommand, 54: .maskCommand, 56: .maskShift, 60: .maskShift]

func post(_ code: CGKeyCode, down: Bool) {
    guard let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down) else { die("no event") }
    if let flag = modifierFlags[code] {  // modifiers arrive as flagsChanged, like a real keyboard
        e.type = .flagsChanged
        e.flags = down ? flag : []
    }
    e.post(tap: .cghidEventTap)
    usleep(50_000)  // exiting right after post can drop the event
}

func focusedText(_ bundleID: String) -> String {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { die("\(bundleID) is not running") }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(ax, kAXFocusedUIElementAttribute as CFString, &focused) == .success else {
        die("no focused element (Accessibility not granted?)")
    }
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, &value)
    return value as? String ?? ""
}

/// Number of windows of one process (by pid, not bundle id: two copies of the app may be running).
func windowCount(_ pid: pid_t) -> Int {
    let ax = AXUIElementCreateApplication(pid)
    var windows: CFTypeRef?
    guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &windows) == .success else {
        die("cannot read windows of \(pid) (Accessibility not granted, or no such process)")
    }
    return (windows as? [AXUIElement])?.count ?? 0
}

func keycode(_ s: String) -> CGKeyCode {
    guard let c = CGKeyCode(s) else { die("bad keycode \(s)") }
    return c
}

let args = CommandLine.arguments.dropFirst()
switch (args.first, args.dropFirst().first) {
case ("trusted", _):  // also asks macOS to show the Accessibility prompt for the app running this tool
    let ok = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    print(ok); exit(ok ? 0 : 1)
case ("is-trusted", _):  // the same answer without showing any prompt
    let ok = AXIsProcessTrusted()
    print(ok); exit(ok ? 0 : 1)
case ("key-down", let c?): post(keycode(c), down: true)
case ("key-up", let c?): post(keycode(c), down: false)
case ("field-text", let b?): print(focusedText(b))
case ("window-count", let p?):
    guard let pid = pid_t(p) else { die("bad pid \(p)") }
    print(windowCount(pid))
default: die("usage: e2e-helper trusted | is-trusted | key-down <keycode> | key-up <keycode> | field-text <bundle-id> | window-count <pid>")
}
