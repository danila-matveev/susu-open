import Foundation

// Pure hotkey state machine (spec 3.1). No system calls: the driver feeds events with
// timestamps (seconds) and calls `tick(at:)` when `nextDeadline` passes.

/// The key that starts dictation. A modifier is detected via flagsChanged, a normal key
/// (for example F18) via keyDown/keyUp.
public struct HotkeyTrigger: Sendable, Equatable {
    public var keyCode: UInt16
    public var isModifier: Bool
    /// Device-independent CGEventFlags raw mask: the modifier itself, or for a normal key the
    /// modifiers that must be held with it (0 = none).
    public var flagMask: UInt64

    public init(keyCode: UInt16, isModifier: Bool, flagMask: UInt64) {
        self.keyCode = keyCode
        self.isModifier = isModifier
        self.flagMask = flagMask
    }

    /// Control, Option, Command, Shift (device-independent CGEventFlags).
    public static let modifierFlagsMask: UInt64 = 0x40000 | 0x80000 | 0x100000 | 0x20000

    /// Function keys F1–F20: the only normal keys allowed as a trigger without modifiers
    /// (a bare letter or Space would start a recording while typing).
    public static let bareKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    /// A normal key plus the exact modifiers that must be held (`flagMask`, 0 = none).
    /// Nil for a bare key that is not a function key.
    public static func key(_ keyCode: UInt16, modifiers flagMask: UInt64) -> HotkeyTrigger? {
        guard flagMask != 0 || bareKeyCodes.contains(keyCode) else { return nil }
        return HotkeyTrigger(keyCode: keyCode, isModifier: false, flagMask: flagMask)
    }

    /// Key-down of a normal-key trigger: same key and exactly the required modifiers.
    public func matchesKeyDown(keyCode: UInt16, flags: UInt64) -> Bool {
        !isModifier && keyCode == self.keyCode && flags & Self.modifierFlagsMask == flagMask
    }

    public static let leftControl = HotkeyTrigger(keyCode: 59, isModifier: true, flagMask: 0x40000)
    public static let rightControl = HotkeyTrigger(keyCode: 62, isModifier: true, flagMask: 0x40000)
    public static let leftOption = HotkeyTrigger(keyCode: 58, isModifier: true, flagMask: 0x80000)
    public static let rightOption = HotkeyTrigger(keyCode: 61, isModifier: true, flagMask: 0x80000)
    public static let leftCommand = HotkeyTrigger(keyCode: 55, isModifier: true, flagMask: 0x100000)
    public static let rightCommand = HotkeyTrigger(keyCode: 54, isModifier: true, flagMask: 0x100000)
    /// A function key as trigger (default for development, when Ctrl is taken by another app).
    public static let f18 = HotkeyTrigger(keyCode: 79, isModifier: false, flagMask: 0)
}

public struct HotkeyConfig: Sendable, Equatable {
    public var trigger: HotkeyTrigger
    public var holdThreshold: TimeInterval
    public var doubleTapWindow: TimeInterval
    /// False for the agent instance (right Option): it never enters hands-free.
    public var allowHandsFree: Bool

    public init(
        trigger: HotkeyTrigger = .leftControl,
        holdThreshold: TimeInterval = 0.3,
        doubleTapWindow: TimeInterval = 0.4,
        allowHandsFree: Bool = true
    ) {
        self.trigger = trigger
        self.holdThreshold = holdThreshold
        self.doubleTapWindow = doubleTapWindow
        self.allowHandsFree = allowHandsFree
    }
}

public enum HotkeyEvent: Sendable, Equatable {
    case triggerDown
    case triggerUp
    /// Any other key (including other modifiers) pressed.
    case otherKeyDown(keyCode: UInt16)
    case escape
    /// Space pressed (Ctrl+Space starts hands-free).
    case space
}

public enum HotkeyCancelReason: Sendable, Equatable {
    case combo
    case escape
    case shortTap
    /// The event tap was lost (sleep, secure input), so key state is unknown.
    case tapLost
}

public enum HotkeyAction: Sendable, Equatable {
    /// Trigger pressed: start the microphone right away (spec 1.4).
    case startMic
    /// Hold threshold passed: this is dictation, begin STT and show the wave.
    case confirmDictation
    /// Hands-free recording began (double tap or trigger+Space).
    case startHandsFree
    /// Stop recording and insert the text.
    case finish
    /// Drop the recording. For `.escape` the driver must also swallow the Esc key.
    case cancel(HotkeyCancelReason)
}

public enum HotkeyState: Sendable, Equatable {
    case idle
    case pressed(at: TimeInterval)
    case holding
    case tapReleased(at: TimeInterval)
    case handsFree
    case cancelled
}

public struct HotkeyMachine: Sendable {
    public let config: HotkeyConfig
    public private(set) var state: HotkeyState = .idle

    public init(config: HotkeyConfig = HotkeyConfig()) {
        self.config = config
    }

    /// True while audio is being recorded; the tap swallows Esc only then.
    public var isRecording: Bool {
        switch state {
        case .pressed, .holding, .handsFree: true
        case .idle, .tapReleased, .cancelled: false
        }
    }

    /// When the driver must call `tick(at:)` next (nil: no timer needed).
    public var nextDeadline: TimeInterval? {
        switch state {
        case .pressed(let t): t + config.holdThreshold
        case .tapReleased(let t): t + config.doubleTapWindow
        default: nil
        }
    }

    public mutating func handle(_ event: HotkeyEvent, at t: TimeInterval) -> [HotkeyAction] {
        switch event {
        case .triggerDown: return triggerDown(at: t)
        case .triggerUp: return triggerUp(at: t)
        case .otherKeyDown: return otherKey()
        case .escape: return escape()
        case .space: return space()
        }
    }

    /// Time passes without events: crosses the hold threshold or expires the double-tap window.
    public mutating func tick(at t: TimeInterval) -> [HotkeyAction] {
        switch state {
        case .pressed(let t0) where t - t0 >= config.holdThreshold:
            state = .holding
            return [.confirmDictation]
        case .tapReleased(let t0) where t - t0 >= config.doubleTapWindow:
            state = .idle
            return []
        default:
            return []
        }
    }

    /// The event tap was disabled and re-enabled: key-up events may have been missed.
    public mutating func reset() -> [HotkeyAction] {
        let wasRecording = isRecording
        state = .idle
        return wasRecording ? [.cancel(.tapLost)] : []
    }

    // MARK: - Transitions

    private mutating func triggerDown(at t: TimeInterval) -> [HotkeyAction] {
        switch state {
        case .idle, .cancelled:
            state = .pressed(at: t)
            return [.startMic]
        case .tapReleased(let t0):
            if t - t0 <= config.doubleTapWindow {
                state = .handsFree
                return [.startMic, .startHandsFree]
            }
            state = .pressed(at: t)
            return [.startMic]
        case .handsFree:
            state = .idle
            return [.finish]
        case .pressed, .holding:
            return []  // key repeat
        }
    }

    private mutating func triggerUp(at t: TimeInterval) -> [HotkeyAction] {
        switch state {
        case .pressed(let t0):
            if t - t0 >= config.holdThreshold {
                // Released after the threshold but before any tick: it was a hold.
                state = .idle
                return [.confirmDictation, .finish]
            }
            state = config.allowHandsFree ? .tapReleased(at: t) : .idle
            return [.cancel(.shortTap)]
        case .holding:
            state = .idle
            return [.finish]
        case .cancelled:
            state = .idle
            return []
        case .idle, .tapReleased, .handsFree:
            return []
        }
    }

    private mutating func otherKey() -> [HotkeyAction] {
        switch state {
        case .pressed, .holding:
            state = .cancelled
            return [.cancel(.combo)]
        case .tapReleased:
            state = .idle  // typing between taps: not a double tap
            return []
        case .idle, .handsFree, .cancelled:
            return []
        }
    }

    private mutating func escape() -> [HotkeyAction] {
        switch state {
        case .pressed, .holding:
            state = .cancelled  // wait for the trigger release
            return [.cancel(.escape)]
        case .handsFree:
            state = .idle
            return [.cancel(.escape)]
        case .tapReleased:
            state = .idle
            return []
        case .idle, .cancelled:
            return []
        }
    }

    private mutating func space() -> [HotkeyAction] {
        switch state {
        case .pressed, .holding:
            guard config.allowHandsFree else { return otherKey() }
            state = .handsFree
            return [.startHandsFree]
        case .tapReleased:
            state = .idle
            return []
        case .idle, .handsFree, .cancelled:
            return []
        }
    }
}
