import Testing

@testable import SusuCore

private enum Step: Sendable {
    case event(Double, HotkeyEvent)
    case tick(Double)
}

private struct Scenario: Sendable, CustomTestStringConvertible {
    var name: String
    var config = HotkeyConfig(trigger: .f18)
    var steps: [Step]
    var expected: [HotkeyAction]
    var finalState: HotkeyState
    var testDescription: String { name }
}

private let agentConfig = HotkeyConfig(trigger: .rightOption, allowHandsFree: false)

private let scenarios: [Scenario] = [
    Scenario(
        name: "hold 1 s with tick -> dictation, release finishes",
        steps: [.event(0, .triggerDown), .tick(0.3), .event(1.0, .triggerUp)],
        expected: [.startMic, .confirmDictation, .finish], finalState: .idle),
    Scenario(
        name: "release at 0.31 s without tick still counts as hold",
        steps: [.event(0, .triggerDown), .event(0.31, .triggerUp)],
        expected: [.startMic, .confirmDictation, .finish], finalState: .idle),
    Scenario(
        name: "release at 0.29 s is a short tap (hands-free allowed)",
        steps: [.event(0, .triggerDown), .event(0.29, .triggerUp)],
        expected: [.startMic, .cancel(.shortTap)], finalState: .tapReleased(at: 0.29)),
    Scenario(
        name: "release at 0.29 s, agent instance: idle after short tap",
        config: agentConfig,
        steps: [.event(0, .triggerDown), .event(0.29, .triggerUp)],
        expected: [.startMic, .cancel(.shortTap)], finalState: .idle),
    Scenario(
        name: "tick at 0.29 s does nothing",
        steps: [.event(0, .triggerDown), .tick(0.29)],
        expected: [.startMic], finalState: .pressed(at: 0)),
    Scenario(
        name: "tick at 0.31 s confirms dictation",
        steps: [.event(0, .triggerDown), .tick(0.31)],
        expected: [.startMic, .confirmDictation], finalState: .holding),
    Scenario(
        name: "Ctrl+C while pressed cancels silently, release is quiet",
        steps: [.event(0, .triggerDown), .event(0.1, .otherKeyDown(keyCode: 8)), .event(0.2, .triggerUp)],
        expected: [.startMic, .cancel(.combo)], finalState: .idle),
    Scenario(
        name: "Ctrl+C while holding cancels",
        steps: [.event(0, .triggerDown), .tick(0.3), .event(0.8, .otherKeyDown(keyCode: 8)), .event(1.0, .triggerUp)],
        expected: [.startMic, .confirmDictation, .cancel(.combo)], finalState: .idle),
    Scenario(
        name: "second other key after combo does not cancel twice",
        steps: [
            .event(0, .triggerDown), .event(0.1, .otherKeyDown(keyCode: 8)),
            .event(0.2, .otherKeyDown(keyCode: 9)),
        ],
        expected: [.startMic, .cancel(.combo)], finalState: .cancelled),
    Scenario(
        name: "double tap -> hands-free",
        steps: [.event(0, .triggerDown), .event(0.1, .triggerUp), .event(0.3, .triggerDown), .event(0.4, .triggerUp)],
        expected: [.startMic, .cancel(.shortTap), .startMic, .startHandsFree], finalState: .handsFree),
    Scenario(
        name: "second tap 0.39 s after release still double tap",
        steps: [.event(0, .triggerDown), .event(0.1, .triggerUp), .event(0.49, .triggerDown)],
        expected: [.startMic, .cancel(.shortTap), .startMic, .startHandsFree], finalState: .handsFree),
    Scenario(
        name: "second tap 0.41 s after release is a new press",
        steps: [.event(0, .triggerDown), .event(0.1, .triggerUp), .event(0.51, .triggerDown)],
        expected: [.startMic, .cancel(.shortTap), .startMic], finalState: .pressed(at: 0.51)),
    Scenario(
        name: "window expires on tick -> idle",
        steps: [.event(0, .triggerDown), .event(0.1, .triggerUp), .tick(0.5)],
        expected: [.startMic, .cancel(.shortTap)], finalState: .idle),
    Scenario(
        name: "typing between taps breaks the double tap",
        steps: [
            .event(0, .triggerDown), .event(0.1, .triggerUp), .event(0.2, .otherKeyDown(keyCode: 0)),
            .event(0.3, .triggerDown),
        ],
        expected: [.startMic, .cancel(.shortTap), .startMic], finalState: .pressed(at: 0.3)),
    Scenario(
        name: "long first press (0.31 s) is not a tap, next press is single",
        steps: [.event(0, .triggerDown), .event(0.31, .triggerUp), .event(0.5, .triggerDown)],
        expected: [.startMic, .confirmDictation, .finish, .startMic], finalState: .pressed(at: 0.5)),
    Scenario(
        name: "trigger in hands-free finishes; its release is ignored",
        steps: [
            .event(0, .triggerDown), .event(0.1, .triggerUp), .event(0.3, .triggerDown),
            .event(0.4, .triggerUp), .event(5, .triggerDown), .event(5.1, .triggerUp),
        ],
        expected: [.startMic, .cancel(.shortTap), .startMic, .startHandsFree, .finish], finalState: .idle),
    Scenario(
        name: "Esc while holding cancels, release quiet",
        steps: [.event(0, .triggerDown), .tick(0.3), .event(1, .escape), .event(1.2, .triggerUp)],
        expected: [.startMic, .confirmDictation, .cancel(.escape)], finalState: .idle),
    Scenario(
        name: "Esc in hands-free cancels",
        steps: [
            .event(0, .triggerDown), .event(0.1, .triggerUp), .event(0.3, .triggerDown),
            .event(0.4, .triggerUp), .event(3, .escape),
        ],
        expected: [.startMic, .cancel(.shortTap), .startMic, .startHandsFree, .cancel(.escape)],
        finalState: .idle),
    Scenario(
        name: "Esc in idle does nothing",
        steps: [.event(0, .escape)],
        expected: [], finalState: .idle),
    Scenario(
        name: "agent instance never enters hands-free on double tap",
        config: agentConfig,
        steps: [.event(0, .triggerDown), .event(0.1, .triggerUp), .event(0.3, .triggerDown), .event(0.4, .triggerUp)],
        expected: [.startMic, .cancel(.shortTap), .startMic, .cancel(.shortTap)], finalState: .idle),
    Scenario(
        name: "Ctrl+Space while pressed -> hands-free, release ignored, trigger finishes",
        steps: [
            .event(0, .triggerDown), .event(0.1, .space), .event(0.2, .triggerUp),
            .event(4, .triggerDown),
        ],
        expected: [.startMic, .startHandsFree, .finish], finalState: .idle),
    Scenario(
        name: "Ctrl+Space while holding -> hands-free",
        steps: [.event(0, .triggerDown), .tick(0.3), .event(1, .space)],
        expected: [.startMic, .confirmDictation, .startHandsFree], finalState: .handsFree),
    Scenario(
        name: "Ctrl+Space on agent instance is a combo cancel",
        config: agentConfig,
        steps: [.event(0, .triggerDown), .event(0.1, .space)],
        expected: [.startMic, .cancel(.combo)], finalState: .cancelled),
    Scenario(
        name: "Space without trigger does nothing",
        steps: [.event(0, .space)],
        expected: [], finalState: .idle),
    Scenario(
        name: "key repeat of trigger is ignored",
        steps: [.event(0, .triggerDown), .event(0.05, .triggerDown), .tick(0.3), .event(0.35, .triggerDown)],
        expected: [.startMic, .confirmDictation], finalState: .holding),
    Scenario(
        name: "custom thresholds: 0.5 s hold",
        config: HotkeyConfig(trigger: .f18, holdThreshold: 0.5),
        steps: [.event(0, .triggerDown), .event(0.4, .triggerUp)],
        expected: [.startMic, .cancel(.shortTap)], finalState: .tapReleased(at: 0.4)),
]

@Suite("HotkeyMachine")
struct HotkeyMachineTests {
    @Test("scenario", arguments: scenarios)
    private func scenario(_ s: Scenario) {
        var machine = HotkeyMachine(config: s.config)
        var actions: [HotkeyAction] = []
        for step in s.steps {
            switch step {
            case .event(let t, let e): actions += machine.handle(e, at: t)
            case .tick(let t): actions += machine.tick(at: t)
            }
        }
        #expect(actions == s.expected)
        #expect(machine.state == s.finalState)
    }

    @Test func isRecordingFollowsState() {
        var m = HotkeyMachine(config: HotkeyConfig(trigger: .f18))
        #expect(!m.isRecording)
        _ = m.handle(.triggerDown, at: 0)
        #expect(m.isRecording)
        _ = m.handle(.triggerUp, at: 0.1)  // short tap, waiting for second tap
        #expect(!m.isRecording)
        _ = m.handle(.triggerDown, at: 0.2)  // hands-free
        #expect(m.isRecording)
    }

    @Test func nextDeadline() {
        var m = HotkeyMachine(config: HotkeyConfig(trigger: .f18))
        #expect(m.nextDeadline == nil)
        _ = m.handle(.triggerDown, at: 10)
        #expect(m.nextDeadline == 10.3)
        _ = m.handle(.triggerUp, at: 10.1)
        #expect(m.nextDeadline == 10.1 + 0.4)
    }

    @Test func resetCancelsActiveRecordingOnly() {
        var m = HotkeyMachine(config: HotkeyConfig(trigger: .f18))
        #expect(m.reset().isEmpty)
        _ = m.handle(.triggerDown, at: 0)
        #expect(m.reset() == [.cancel(.tapLost)])
        #expect(m.state == .idle)
    }

    @Test func triggerPresetsUseSideSpecificKeycodes() {
        #expect(HotkeyTrigger.leftControl.keyCode == 59)
        #expect(HotkeyTrigger.rightControl.keyCode == 62)
        #expect(HotkeyTrigger.leftOption.keyCode == 58)
        #expect(HotkeyTrigger.rightOption.keyCode == 61)
        #expect(HotkeyTrigger.leftCommand.keyCode == 55)
        #expect(HotkeyTrigger.rightCommand.keyCode == 54)
        #expect(!HotkeyTrigger.f18.isModifier)
    }
}
