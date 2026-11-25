#if os(macOS)
import AppKit

public enum InsertStatus: String, Sendable, Equatable {
    case inserted
    /// Left on the pasteboard for the user (other window/field).
    case copiedOnly = "copied_only"
    /// The app did not take the text within the timeout.
    case notInserted = "not_inserted"
}

public struct InsertResult: Sendable, Equatable {
    public var status: InsertStatus
    /// t1: when the target app asked for the text (Clock time). Nil unless `.inserted`.
    public var takenAt: TimeInterval?
    public init(status: InsertStatus, takenAt: TimeInterval? = nil) {
        self.status = status; self.takenAt = takenAt
    }
}

/// Spec 3.6. Puts text on the pasteboard as a lazy promise, presses Cmd+V, notices when the app
/// reads it (t1), and gives the user's old pasteboard back.
public final class Inserter: @unchecked Sendable {
    public static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    public static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private let pasteboard: NSPasteboard
    private let clock: SusuClock
    private let pressPaste: @Sendable () -> Void
    private let pressReturnKey: @Sendable () -> Void
    private let takeTimeout: TimeInterval
    private let restoreDelay: TimeInterval

    public init(pasteboard: NSPasteboard = .general,
                clock: SusuClock = SystemClock(),
                pressPaste: @escaping @Sendable () -> Void = { KeySynthesis.pressCommandV() },
                pressReturn: @escaping @Sendable () -> Void = { KeySynthesis.pressReturn() },
                takeTimeout: TimeInterval = 0.5,
                restoreDelay: TimeInterval = 0.15) {
        self.pasteboard = pasteboard
        self.clock = clock
        self.pressPaste = pressPaste
        self.pressReturnKey = pressReturn
        self.takeTimeout = takeTimeout
        self.restoreDelay = restoreDelay
    }

    /// Returns after the old pasteboard is restored (about 150 ms after `takenAt`); `takenAt` is
    /// already final at that point, so callers compute latency from it.
    public func insert(text: String, expected: ContextSnapshot?, current: ContextSnapshot?) async -> InsertResult {
        // Never paste into a password field, and never into a window we cannot prove is the original one.
        if current?.isSecureField == true || Self.targetChanged(expected: expected, current: current) {
            copyToPasteboard(text)
            return InsertResult(status: .copiedOnly)
        }

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let provider = PromiseProvider(text: text, clock: clock)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        item.setData(Data(), forType: Self.transientType)
        item.setData(Data(), forType: Self.concealedType)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let ourChangeCount = pasteboard.changeCount

        pressPaste()
        let asked = await provider.waitUntilRequested(clock: clock, timeout: takeTimeout)

        if asked {
            try? await clock.sleep(seconds: restoreDelay)
        }
        // Someone else wrote to the pasteboard meanwhile: their data wins.
        if pasteboard.changeCount == ourChangeCount {
            snapshot.restore(to: pasteboard)
        }
        withExtendedLifetime(provider) {}
        return asked ? InsertResult(status: .inserted, takenAt: provider.takenAt)
                     : InsertResult(status: .notInserted)
    }

    /// For the voice command "нажми Enter".
    public func pressReturn() { pressReturnKey() }

    /// Permanent copy for the user to paste themselves (no transient markers).
    public func copyToPasteboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Different app, or different focused field. No `expected` means the caller did not track a target
    /// (paste-last); a known start app with an unknown current app counts as changed (fail safe).
    /// Element IDs stay best-effort: many apps expose none.
    static func targetChanged(expected: ContextSnapshot?, current: ContextSnapshot?) -> Bool {
        guard let expected else { return false }
        guard let current else { return expected.pid != nil }
        if let a = expected.pid, a != current.pid { return true }
        if let a = expected.focusedElementID, let b = current.focusedElementID, a != b { return true }
        return false
    }
}

/// Lazy pasteboard data: called by the target app when it reads the text.
private final class PromiseProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let text: String
    private let clock: SusuClock
    private let lock = NSLock()
    private var _takenAt: TimeInterval?
    private var outcome: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    init(text: String, clock: SusuClock) {
        self.text = text
        self.clock = clock
        super.init()
    }

    var takenAt: TimeInterval? { lock.withLock { _takenAt } }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        item.setData(Data(text.utf8), forType: type)
        lock.withLock { if _takenAt == nil { _takenAt = clock.now() } }
        finish(true)
    }

    /// First call wins; later ones are ignored.
    private func finish(_ value: Bool) {
        let cont: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = value
            defer { waiter = nil }
            return waiter
        }
        cont?.resume(returning: value)
    }

    /// True as soon as the data was requested; false after `timeout` on the injected clock.
    func waitUntilRequested(clock: SusuClock, timeout: TimeInterval) async -> Bool {
        let timer = Task { [weak self] in
            try? await clock.sleep(seconds: timeout)
            if !Task.isCancelled { self?.finish(false) }
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let ready: Bool? = lock.withLock {
                if let outcome { return outcome }
                waiter = cont
                return nil
            }
            if let ready { cont.resume(returning: ready) }
        }
    }
}
#endif
