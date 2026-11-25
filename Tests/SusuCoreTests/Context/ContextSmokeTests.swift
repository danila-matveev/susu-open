#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import SusuCore

/// Manual smoke check against real apps. Off by default; run with
/// `SUSU_CONTEXT_SMOKE=com.apple.TextEdit,com.google.Chrome swift test --filter ContextSmokeTests`.
/// Snapshots each listed running app (it need not be frontmost; bring it forward first for realistic focus) and prints a redacted summary (lengths, not text).
@Suite struct ContextSmokeTests {
    static let apps = ProcessInfo.processInfo.environment["SUSU_CONTEXT_SMOKE"]?
        .split(separator: ",").map(String.init) ?? []

    @Test(.enabled(if: !apps.isEmpty), arguments: apps)
    func snapshotApp(bundleID: String) async throws {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            print("SMOKE \(bundleID): not running"); return
        }
        func run() -> (ContextSnapshot, Double) {
            let t = DispatchTime.now()
            let s = ContextSnapshotter.snapshot(of: app, exclusions: ContextRules.defaultExclusions, honorSecureInput: false)
            return (s, Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e6)
        }
        let (first, ms1) = run()
        let (second, ms2) = run()
        let focus = ContextSnapshotter.currentFocus()
        let host = first.url.map { String($0.prefix { $0 != "/" }) } ?? "nil"
        print("""
        SMOKE \(bundleID): secureInputOn=\(IsSecureEventInputEnabled()) app=\(first.bundleID ?? "nil") pid=\(first.pid.map(String.init) ?? "nil") \
        title.len=\(first.windowTitle?.count ?? -1) urlHost=\(host) urlHasPath=\((first.url ?? "").contains("/")) \
        role=\(first.focusedRole ?? "nil") id=\(first.focusedElementID ?? "nil") \
        before.len=\(first.textBeforeCursor?.count ?? -1) sel.len=\(first.selectedText?.count ?? -1) \
        secure=\(first.isSecureField) excluded=\(first.excluded) ms=\(String(format: "%.1f/%.1f", ms1, ms2)) \
        sameTarget(snap,snap)=\(ContextSnapshotter.isSameTarget(first, second)) \
        sameTarget(snap,focus)=\(ContextSnapshotter.isSameTarget(first, focus))
        """)
    }
}
#endif

#if os(macOS)
extension ContextSmokeTests {
    /// Moves the caret to the end of the open TextEdit document (a scratch file) and checks the 500-char tail.
    @Test(.enabled(if: !apps.isEmpty && apps.contains("com.apple.TextEdit")))
    func textEditCaretAtEnd() throws {
        let app = try #require(NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.TextEdit" })
        let ax = AX.appElement(pid: app.processIdentifier)
        let el = try #require(AX.focusedElement(pid: app.processIdentifier, app: ax))
        let len = (AX.string(el, kAXValueAttribute) ?? "").utf16.count
        var r = CFRange(location: len, length: 0)
        AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &r)!)
        let s = ContextSnapshotter.snapshot(of: app, exclusions: [], honorSecureInput: false)
        print("SMOKE TextEdit caret-end: role=\(s.focusedRole ?? "nil") before.len=\(s.textBeforeCursor?.count ?? -1) tail=\(s.textBeforeCursor.map { String($0.suffix(8)) } ?? "nil") title=\(s.windowTitle ?? "nil")")
        #expect(s.textBeforeCursor?.count == 500)
        #expect(s.textBeforeCursor?.hasSuffix("конец") == true)
    }
}
#endif

#if os(macOS)
extension ContextSmokeTests {
    /// Edits the scratch TextEdit document through AX and expects the observer stream to report it.
    @Test(.enabled(if: !apps.isEmpty && apps.contains("com.apple.TextEdit")))
    func textEditObserveValue() async throws {
        let app = try #require(NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.TextEdit" })
        app.activate()
        try await Task.sleep(nanoseconds: 500_000_000)
        let focus = ContextSnapshotter.currentFocus()
        let id = try #require(focus.focusedElementID)
        let before = try #require(FieldValueReader.read(pid: app.processIdentifier, elementID: id))
        let stream = FieldValueReader.observeValue(pid: app.processIdentifier, elementID: id, deadline: 5, pollInterval: 0.3)
        let el = try #require(AX.focusedElement(pid: app.processIdentifier, app: AX.appElement(pid: app.processIdentifier)))
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, (before + " edited") as CFString)
        var got: String?
        for await v in stream { got = v; break }
        print("SMOKE observeValue: got.suffix=\(got.map { String($0.suffix(7)) } ?? "nil")")
        #expect(got?.hasSuffix("edited") == true)
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, before as CFString)
    }
}
#endif
