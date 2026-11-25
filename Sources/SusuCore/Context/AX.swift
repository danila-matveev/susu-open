#if os(macOS)
import ApplicationServices
import AppKit

/// Thin typed wrappers over the Accessibility C API. All reads return nil on any AX error.
enum AX {
    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        guard let v = attr(el, name) else { return nil }
        if let s = v as? String { return s }
        if CFGetTypeID(v) == CFURLGetTypeID() { return (v as! URL).absoluteString }
        return nil
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func range(_ el: AXUIElement, _ name: String) -> CFRange? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        return r
    }

    static func stringForRange(_ el: AXUIElement, _ r: CFRange) -> String? {
        var rr = r
        guard let param = AXValueCreate(.cfRange, &rr) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, param, &out) == .success
        else { return nil }
        return out as? String
    }

    static func pid(_ el: AXUIElement) -> Int32? {
        var p: pid_t = 0
        return AXUIElementGetPid(el, &p) == .success ? p : nil
    }

    static func appElement(pid: Int32, timeout: Float = 0.05) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return app
    }

    /// The focused UI element: asked of the system-wide element first, then of the app itself
    /// (some apps answer only one of the two). Result must belong to `pid`.
    static func focusedElement(pid: Int32, app: AXUIElement) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        if let el = element(system, kAXFocusedUIElementAttribute), Self.pid(el) == pid { return el }
        return element(app, kAXFocusedUIElementAttribute)
    }
}

/// `AXUIElement` is a CF type that is safe to pass between threads for read-only use.
struct SendableAXElement: @unchecked Sendable { let element: AXUIElement }
#endif
