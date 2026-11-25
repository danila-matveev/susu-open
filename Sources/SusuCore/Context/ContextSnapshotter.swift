#if os(macOS)
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// Captures "where the user is" at key-down (spec 2.5, 3.6, 9.6). Accessibility only, no AppleScript.
/// Budget is 30 ms; every AX call has a 50 ms messaging timeout, and the browser-address search has its own
/// time box, so a hung app cannot stall dictation for long.
public enum ContextSnapshotter {
    private static let log = Logger(subsystem: "app.susu", category: "context")

    /// Browsers whose tab address is read from the AX tree.
    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "ru.yandex.desktop.yandex-browser", "company.thebrowser.Browser",
    ]

    /// Full snapshot of the frontmost app. Never reads text from excluded apps or secure fields.
    public static func snapshot(exclusions: Set<String> = ContextRules.defaultExclusions) -> ContextSnapshot {
        guard let front = NSWorkspace.shared.frontmostApplication else { return ContextSnapshot() }
        return snapshot(of: front, exclusions: exclusions)
    }

    /// Same for a given running app (the frontmost one in production; any app in the manual smoke test).
    /// `honorSecureInput: false` skips the system-wide Secure Event Input check (smoke test only).
    static func snapshot(of front: NSRunningApplication, exclusions: Set<String>, honorSecureInput: Bool = true) -> ContextSnapshot {
        let started = DispatchTime.now()
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
            log.debug("snapshot took \(ms, format: .fixed(precision: 1)) ms")
        }
        var snap = ContextSnapshot(appName: front.localizedName, bundleID: front.bundleIdentifier, pid: front.processIdentifier)

        if ContextRules.isExcluded(bundleID: front.bundleIdentifier, exclusions: exclusions) {
            snap.excluded = true
            return snap
        }
        let pid = front.processIdentifier
        let app = AX.appElement(pid: pid)

        let focused = AX.focusedElement(pid: pid, app: app)
        if let focused {
            snap.focusedRole = AX.string(focused, kAXRoleAttribute)
            snap.focusedElementID = elementID(focused, pid: pid, role: snap.focusedRole)
            let subrole = AX.string(focused, kAXSubroleAttribute)
            if snap.focusedRole == "AXSecureTextField" || subrole == "AXSecureTextField" {
                snap.isSecureField = true
                return snap
            }
        }
        if honorSecureInput, IsSecureEventInputEnabled() {
            snap.isSecureField = true
            return snap
        }

        let window = AX.element(app, kAXFocusedWindowAttribute)
        if let window { snap.windowTitle = AX.string(window, kAXTitleAttribute) }

        if let focused {
            readText(of: focused, into: &snap)
        }
        if let id = front.bundleIdentifier, browserBundleIDs.contains(id) {
            snap.url = browserURL(app: app, window: window, focused: focused)
        }
        return snap
    }

    /// Light version for the moment right before insertion: pid + element id only.
    public static func currentFocus() -> ContextSnapshot {
        guard let front = NSWorkspace.shared.frontmostApplication else { return ContextSnapshot() }
        let pid = front.processIdentifier
        var snap = ContextSnapshot(appName: front.localizedName, bundleID: front.bundleIdentifier, pid: pid)
        let app = AX.appElement(pid: pid)
        if let focused = AX.focusedElement(pid: pid, app: app) {
            snap.focusedRole = AX.string(focused, kAXRoleAttribute)
            snap.focusedElementID = elementID(focused, pid: pid, role: snap.focusedRole)
            if snap.focusedRole == "AXSecureTextField" || AX.string(focused, kAXSubroleAttribute) == "AXSecureTextField" {
                snap.isSecureField = true
            }
        }
        // A password field took the keyboard since the recording started: the inserter must not paste.
        if IsSecureEventInputEnabled() { snap.isSecureField = true }
        return snap
    }

    /// Focused field id + its whole value (for the edit watcher, T2.7). nil for password fields or huge documents.
    public static func focusedValue(maxLength: Int = 20_000) -> (id: String, value: String)? {
        guard let front = NSWorkspace.shared.frontmostApplication, !IsSecureEventInputEnabled() else { return nil }
        let pid = front.processIdentifier
        guard let el = AX.focusedElement(pid: pid, app: AX.appElement(pid: pid)) else { return nil }
        let role = AX.string(el, kAXRoleAttribute)
        guard role != "AXSecureTextField", let value = AX.string(el, kAXValueAttribute), value.utf16.count <= maxLength else { return nil }
        return (elementID(el, pid: pid, role: role), value)
    }

    public static func isSameTarget(_ a: ContextSnapshot, _ b: ContextSnapshot) -> Bool {
        ContextRules.isSameTarget(a, b)
    }

    /// Identity of the focused element: `pid:role:CFHash(element)`. `CFHash` of an `AXUIElement` is derived from the
    /// process and the accessibility object it points to, so it stays the same while the field lives and is
    /// unaffected by moving or resizing the window or a growing multi-line field (a frame hash would change).
    /// Two different fields never share it inside one app run; a field the app rebuilds gets a new id, which
    /// only means "paste to clipboard instead of inserting" — the safe side.
    static func elementID(_ el: AXUIElement, pid: Int32, role: String?) -> String {
        "\(pid):\(role ?? "?"):\(CFHash(el))"
    }

    // MARK: - Text

    private static func readText(of el: AXUIElement, into snap: inout ContextSnapshot) {
        let limit = ContextRules.maxTextBeforeCursor
        if var sel = AX.string(el, kAXSelectedTextAttribute), !sel.isEmpty {
            if sel.count > ContextRules.maxSelectedText { sel = String(sel.prefix(ContextRules.maxSelectedText)) }
            snap.selectedText = sel
        }
        guard let caretRange = AX.range(el, kAXSelectedTextRangeAttribute), caretRange.location >= 0 else { return }
        let caret = caretRange.location
        // Cheap path: ask only for the last ~500 UTF-16 units instead of the whole document value.
        let start = max(0, caret - limit - 2)
        let len = caret - start
        if len == 0 { snap.textBeforeCursor = ""; return }
        if let part = AX.stringForRange(el, CFRange(location: start, length: len)) {
            snap.textBeforeCursor = start > 0 ? ContextRules.trimFetchedTail(part) : ContextRules.trimToTail(part)
        } else if let value = AX.string(el, kAXValueAttribute) {
            snap.textBeforeCursor = ContextRules.textBeforeCaret(value, caretUTF16: caret)
        }
    }

    // MARK: - Browser address

    /// Address of the active tab: the `AXURL` of the web area that holds the focus, else `AXDocument` of the
    /// window, else a time-boxed search for an `AXWebArea` in the window. Chromium only builds its web tree
    /// when it sees an assistive client, so on the first miss we set `AXManualAccessibility` once per process.
    static func browserURL(app: AXUIElement, window: AXUIElement?, focused: AXUIElement?) -> String? {
        if let u = urlFromAX(app: app, window: window, focused: focused) { return u }
        guard let pid = AX.pid(app), !enabledPIDs.withLock({ !$0.insert(pid).inserted }) else { return nil }
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return urlFromAX(app: app, window: window, focused: focused)
    }

    private static let enabledPIDs = OSAllocatedUnfairLock<Set<Int32>>(initialState: [])

    private static func urlFromAX(app: AXUIElement, window: AXUIElement?, focused: AXUIElement?) -> String? {
        // 1. Walk up from the focused element to its web area.
        var cur = focused
        for _ in 0..<14 {
            guard let el = cur else { break }
            if AX.string(el, kAXRoleAttribute) == "AXWebArea", let u = AX.string(el, kAXURLAttribute) {
                return ContextRules.normalizeURL(u)
            }
            cur = AX.element(el, kAXParentAttribute)
        }
        guard let window else { return nil }
        // 2. Window document (Safari-style).
        if let doc = AX.string(window, kAXDocumentAttribute), let u = ContextRules.normalizeURL(doc) { return u }
        // 3. Search the window for a web area (focus is in the toolbar / address bar).
        let deadline = DispatchTime.now().uptimeNanoseconds + 12_000_000
        var queue = [window]
        var depthMarker = 0
        while !queue.isEmpty, depthMarker < 400, DispatchTime.now().uptimeNanoseconds < deadline {
            let el = queue.removeFirst(); depthMarker += 1
            if AX.string(el, kAXRoleAttribute) == "AXWebArea" {
                if let u = AX.string(el, kAXURLAttribute) { return ContextRules.normalizeURL(u) }
                continue
            }
            queue.append(contentsOf: AX.children(el))
        }
        return nil
    }
}
#endif
