#if os(macOS)
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// One CGEventTap on its own thread. It listens to flagsChanged/keyDown/keyUp, translates
/// them into `HotkeyEvent`s for every registered handler and swallows only Esc while a
/// handler says it is recording. Needs Accessibility / Input Monitoring permission; not unit-tested.
public final class KeyTap: @unchecked Sendable {
    /// Receives events with the CGEvent timestamp in seconds; returns true to swallow the key.
    public typealias Handler = @Sendable (HotkeyEvent, TimeInterval) -> Bool

    private struct Registration {
        let trigger: HotkeyTrigger
        let handler: Handler
        let onReset: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var registrations: [Registration] = []
    private var heldTriggers: Set<UInt16> = []   // modifier triggers we reported down and not yet up
    private var chords: [(keyCode: UInt16, flags: UInt64, action: @Sendable () -> Void)] = []
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var port: CFMachPort?

    public init() {}

    private static let keyLog = ProcessInfo.processInfo.environment["SUSU_KEYLOG"] == "1"   // E2E debugging

    /// True while a password field (or similar) has Secure Event Input on: no recording then.
    public static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    public func register(
        trigger: HotkeyTrigger,
        onReset: @escaping @Sendable () -> Void = {},
        handler: @escaping Handler
    ) {
        lock.withLock { registrations.append(Registration(trigger: trigger, handler: handler, onReset: onReset)) }
    }

    /// A global key chord (Ctrl+Cmd+V …): exact modifiers, swallowed, `action` runs on the tap thread.
    public func registerChord(keyCode: UInt16, modifiers: [HotkeyModifier], action: @escaping @Sendable () -> Void) {
        let flags = modifiers.reduce(UInt64(0)) { $0 | Self.flag[$1]! }
        lock.withLock { chords.append((keyCode, flags, action)) }
    }

    private static let flag: [HotkeyModifier: UInt64] = [.control: 0x40000, .option: 0x80000, .command: 0x100000, .shift: 0x20000]

    /// Convenience: wire a controller to the tap.
    public func register(_ controller: HotkeyController) {
        register(trigger: controller.trigger, onReset: { controller.reset() }) { event, t in
            controller.handle(event, at: t)
        }
    }

    /// Starts the tap thread. Returns false if the system refused the tap (no permission).
    @discardableResult
    public func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let result = LockedBox(false)
        let thread = Thread { [self] in
            guard let port = makeTap() else { ready.signal(); return }
            self.port = port
            let loop = CFRunLoopGetCurrent()!
            self.runLoop = loop
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(loop, source, .commonModes)
            // Watchdog: re-enable the tap if the system silently disabled it (Д20), and release a modifier
            // trigger whose key-up never reached us (else the recording runs on until the next press).
            let watchdog = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.25, 0.25, 0, 0) { [weak self] _ in
                self?.reenableIfNeeded()
                self?.releaseStuckModifiers()
            }
            CFRunLoopAddTimer(loop, watchdog, .commonModes)
            result.value = true
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "app.susu.keytap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        ready.wait()
        return result.value
    }

    public func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let runLoop { CFRunLoopStop(runLoop) }
        thread = nil
        runLoop = nil
        port = nil
    }

    // MARK: - Tap internals (run on the tap thread)

    private func makeTap() -> CFMachPort? {
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func reenableIfNeeded() {
        guard let port, !CGEvent.tapIsEnabled(tap: port) else { return }
        reenable()
    }

    private func releaseStuckModifiers() {
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        let (regs, held) = lock.withLock { (registrations, heldTriggers) }
        guard !held.isEmpty else { return }
        let t = Self.seconds(mach_absolute_time())
        for reg in regs where reg.trigger.isModifier && held.contains(reg.trigger.keyCode) && flags & reg.trigger.flagMask == 0 {
            lock.withLock { _ = heldTriggers.remove(reg.trigger.keyCode) }
            _ = reg.handler(.triggerUp, t)
        }
    }

    private func reenable() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: true)
        // Key-up events may have been lost while the tap was off.
        let regs = lock.withLock { registrations }
        regs.forEach { $0.onReset() }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenable()
            return Unmanaged.passUnretained(event)
        }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        if Self.keyLog { NSLog("susu keytap type=%d key=%d", type.rawValue, keyCode) }
        let t = Self.seconds(event.timestamp)
        let (regs, chords) = lock.withLock { (registrations, self.chords) }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            let mods = event.flags.rawValue & 0x1E0000
            if let chord = chords.first(where: { $0.keyCode == keyCode && $0.flags == mods }) {
                chord.action()
                return nil
            }
        }
        var swallow = false

        for reg in regs {
            let hotkeyEvent: HotkeyEvent?
            switch type {
            case .flagsChanged:
                if reg.trigger.isModifier && keyCode == reg.trigger.keyCode {
                    let down = event.flags.rawValue & reg.trigger.flagMask != 0
                    hotkeyEvent = down ? .triggerDown : .triggerUp
                    lock.withLock { if down { heldTriggers.insert(keyCode) } else { heldTriggers.remove(keyCode) } }
                } else if let mask = Self.modifierMasks[keyCode], event.flags.rawValue & mask != 0 {
                    hotkeyEvent = .otherKeyDown(keyCode: keyCode)  // Ctrl+Cmd+... counts as a combo
                } else {
                    hotkeyEvent = nil
                }
            case .keyDown:
                if reg.trigger.matchesKeyDown(keyCode: keyCode, flags: event.flags.rawValue) {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    hotkeyEvent = isRepeat ? nil : .triggerDown
                } else if keyCode == UInt16(kVK_Escape) {
                    hotkeyEvent = .escape
                } else if keyCode == UInt16(kVK_Space) {
                    hotkeyEvent = .space
                } else {
                    hotkeyEvent = .otherKeyDown(keyCode: keyCode)
                }
            case .keyUp:
                hotkeyEvent = !reg.trigger.isModifier && keyCode == reg.trigger.keyCode ? .triggerUp : nil
            default:
                hotkeyEvent = nil
            }
            if let hotkeyEvent, reg.handler(hotkeyEvent, t), hotkeyEvent == .escape {
                swallow = true
            }
        }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    /// Left/right modifier keycodes to their flag masks (58/61 Option, 59/62 Ctrl, 55/54 Cmd, 56/60 Shift, 63 Fn).
    private static let modifierMasks: [UInt16: UInt64] = [
        59: 0x40000, 62: 0x40000, 58: 0x80000, 61: 0x80000, 55: 0x100000, 54: 0x100000,
        56: 0x20000, 60: 0x20000, 63: 0x800000,
    ]

    /// CGEventTimestamp is in mach absolute time units; convert to seconds.
    private static func seconds(_ timestamp: CGEventTimestamp) -> TimeInterval {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(timestamp) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private func keyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}
#endif
