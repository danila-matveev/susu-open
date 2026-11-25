#if os(macOS)
import ApplicationServices
import Foundation

/// Hooks for the edit learner (spec 3.7): read the current text of a field and watch it for changes.
public enum FieldValueReader {
    /// Current value of the focused element, only if it is still the field `elementID` in app `pid`.
    public static func read(pid: Int32, elementID: String) -> String? {
        guard let el = focusedField(pid: pid, elementID: elementID) else { return nil }
        return AX.string(el, kAXValueAttribute)
    }

    /// Stream of the field's new values (changes only, not the initial value). Uses `kAXValueChangedNotification`
    /// when the app delivers it and polls every `pollInterval` seconds regardless. Finishes when the focus
    /// leaves the field or after `deadline` seconds.
    public static func observeValue(pid: Int32, elementID: String, deadline: TimeInterval = 60,
                                    pollInterval: TimeInterval = 2) -> AsyncStream<String> {
        AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let state = ObserveState(pid: pid, elementID: elementID, continuation: continuation)
            state.installObserver()
            let task = Task.detached {
                let end = Date().addingTimeInterval(deadline)
                while !Task.isCancelled, Date() < end {
                    try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1e9))
                    if Task.isCancelled || !state.check() { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                state.removeObserver()
            }
        }
    }

    static func focusedField(pid: Int32, elementID: String) -> AXUIElement? {
        let app = AX.appElement(pid: pid)
        guard let el = AX.focusedElement(pid: pid, app: app) else { return nil }
        let role = AX.string(el, kAXRoleAttribute)
        return ContextSnapshotter.elementID(el, pid: pid, role: role) == elementID ? el : nil
    }
}

/// Shared between the poll task and the AX callback (which runs on the main run loop).
private final class ObserveState: @unchecked Sendable {
    let pid: Int32
    let elementID: String
    let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var last: String?
    private var runLoopSource: CFRunLoopSource?
    private var observer: AXObserver?

    init(pid: Int32, elementID: String, continuation: AsyncStream<String>.Continuation) {
        self.pid = pid; self.elementID = elementID; self.continuation = continuation
        last = FieldValueReader.read(pid: pid, elementID: elementID)
    }

    /// Reads the field; yields if changed. Returns false when focus has left the field (stream should end).
    func check() -> Bool {
        guard let el = FieldValueReader.focusedField(pid: pid, elementID: elementID) else {
            continuation.finish()
            return false
        }
        if let v = AX.string(el, kAXValueAttribute) { publish(v) }
        return true
    }

    private func publish(_ value: String) {
        lock.lock()
        let changed = value != last
        if changed { last = value }
        lock.unlock()
        if changed { continuation.yield(value) }
    }

    func installObserver() {
        guard let el = FieldValueReader.focusedField(pid: pid, elementID: elementID) else { return }
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let state = Unmanaged<ObserveState>.fromOpaque(refcon).takeUnretainedValue()
            if let v = AX.string(element, kAXValueAttribute) { state.publish(v) }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        // The observer keeps `self` alive only through the run loop source; removeObserver() tears it down.
        let refcon = Unmanaged.passRetained(self).toOpaque()
        guard AXObserverAddNotification(obs, el, kAXValueChangedNotification as CFString, refcon) == .success else {
            Unmanaged<ObserveState>.fromOpaque(refcon).release()
            return
        }
        let source = AXObserverGetRunLoopSource(obs)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
        observer = obs
    }

    func removeObserver() {
        guard observer != nil, let source = runLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = nil
        observer = nil
        Unmanaged.passUnretained(self).release()
    }
}
#endif
