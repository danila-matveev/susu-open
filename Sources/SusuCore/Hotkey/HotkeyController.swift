import Foundation

/// Runs one `HotkeyMachine` for a driver: serialises events, schedules the timer for
/// `tick(at:)`, and forwards actions. Works with any event source (KeyTap or a test).
public final class HotkeyController: @unchecked Sendable {
    private let lock = NSLock()
    private var machine: HotkeyMachine
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private let queue = DispatchQueue(label: "app.susu.hotkey.timer")
    private let onAction: @Sendable (HotkeyAction) -> Void

    public init(config: HotkeyConfig, onAction: @escaping @Sendable (HotkeyAction) -> Void) {
        self.machine = HotkeyMachine(config: config)
        self.onAction = onAction
    }

    public var trigger: HotkeyTrigger { lock.withLock { machine.config.trigger } }
    public var isRecording: Bool { lock.withLock { machine.isRecording } }

    /// Feeds one event. Returns true if the physical key press must be swallowed
    /// (only Esc while recording).
    @discardableResult
    public func handle(_ event: HotkeyEvent, at t: TimeInterval) -> Bool {
        let (actions, swallow) = lock.withLock { () -> ([HotkeyAction], Bool) in
            let swallow = event == .escape && machine.isRecording
            let actions = machine.handle(event, at: t)
            scheduleTimerLocked()
            return (actions, swallow)
        }
        actions.forEach(onAction)
        return swallow
    }

    /// Call after the event tap was re-enabled: key-up events may have been lost.
    public func reset() {
        let actions = lock.withLock { () -> [HotkeyAction] in
            let actions = machine.reset()
            scheduleTimerLocked()
            return actions
        }
        actions.forEach(onAction)
    }

    // The timer fires `tick(at: deadline)`: machine time stays independent of the system clock.
    private func scheduleTimerLocked() {
        generation += 1
        timer?.cancel()
        timer = nil
        guard let deadline = machine.nextDeadline else { return }
        let started = machine.state
        let delay = max(0, deadline - Self.baseTime(of: started))
        let myGeneration = generation
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + delay)
        source.setEventHandler { [weak self] in self?.fire(at: deadline, generation: myGeneration) }
        timer = source
        source.resume()
    }

    private func fire(at deadline: TimeInterval, generation expected: Int) {
        let actions = lock.withLock { () -> [HotkeyAction] in
            guard generation == expected else { return [] }
            let actions = machine.tick(at: deadline)
            scheduleTimerLocked()
            return actions
        }
        actions.forEach(onAction)
    }

    private static func baseTime(of state: HotkeyState) -> TimeInterval {
        switch state {
        case .pressed(let t), .tapReleased(let t): t
        default: 0
        }
    }
}
