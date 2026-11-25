// Demo mode for visual checks. `SUSU_PILL_DEMO=1` cycles through every state (about 1.5 s each, fake mic level);
// `SUSU_PILL_DEMO=<step>` holds one step (names in `PillDemo.stepNames`), e.g. `hands`, `toast-notpasted`.
// `SUSU_PILL_LANG=en|ru` picks the language of the demo texts.
import AppKit
import SusuCore

@MainActor
public enum PillDemo {
    private struct Step {
        let name: String
        let run: @MainActor (PillController, ToastController, InterfaceLanguage) -> Void
    }

    private static let steps: [Step] = [
        Step(name: "idle") { p, t, _ in t.hide(); p.setCallDot(false); p.setState(.idle) },
        Step(name: "hover") { p, t, _ in t.hide(); p.setCallDot(false); p.setState(.hover) },
        Step(name: "listen-pending") { p, t, _ in t.hide(); p.setState(.listening(confirmed: false)) },
        Step(name: "listen") { p, t, _ in t.hide(); p.setState(.listening(confirmed: true)) },
        Step(name: "hands") { p, t, _ in t.hide(); p.setState(.handsFree) },
        Step(name: "processing") { p, t, _ in t.hide(); p.setState(.processing) },
        Step(name: "agent") { p, t, _ in t.hide(); p.setState(.agentListening) },
        Step(name: "agent-working") { p, t, _ in t.hide(); p.setState(.agentWorking) },
        Step(name: "agent-waiting") { p, t, _ in t.hide(); p.setState(.agentWaiting) },
        Step(name: "note") { p, t, _ in t.hide(); p.setState(.noteListening) },
        Step(name: "call") { p, t, _ in t.hide(); p.setState(.idle); p.setCallDot(true) },
        Step(name: "call-listen") { p, t, _ in t.hide(); p.setCallDot(true); p.setState(.listening(confirmed: true)) },
        Step(name: "error") { p, t, _ in p.setCallDot(false); p.setState(.error) },
        Step(name: "toast-copied") { p, t, l in p.setCallDot(false); p.setState(.idle); t.show(.copied(language: l)) },
        Step(name: "toast-notpasted") { p, t, l in p.setState(.idle); t.show(.notPasted(language: l) {}) },
        Step(name: "toast-micsilent") { p, t, l in p.setState(.idle); t.show(.micSilent(language: l, retry: {}, chooseMicrophone: {})) },
        Step(name: "toast-secure") { p, t, l in p.setState(.idle); t.show(.secureInput(language: l)) },
        Step(name: "toast-remembered") { p, t, l in p.setState(.idle); t.show(.remembered("Анастасия — маркетолог", language: l) {}) },
        Step(name: "toast-nokey") { p, t, l in p.setState(.idle); t.show(.noKey(provider: "Groq", language: l) {}) },
        Step(name: "toast-limit19") { p, t, l in p.setState(.listening(confirmed: true)); t.show(.limit19(language: l)) },
    ]

    @MainActor private final class Counter {
        var i = 0
        func next(_ p: PillController, _ t: ToastController, _ l: InterfaceLanguage) {
            PillDemo.steps[i % PillDemo.steps.count].run(p, t, l)
            i += 1
        }
    }

    public static var stepNames: [String] { steps.map(\.name) }
    private static var timers: [Timer] = []

    /// Call from the app delegate after the pill and toast controllers exist. Does nothing unless `SUSU_PILL_DEMO` is set.
    public static func runIfRequested(pill: PillController, toast: ToastController) {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["SUSU_PILL_DEMO"], !mode.isEmpty, mode != "0" else { return }
        let lang = InterfaceLanguage(rawValue: env["SUSU_PILL_LANG"] ?? "") ?? .ru
        pill.language = lang
        pill.attach(toast)
        pill.menuActions.microphones = { [PillMenuChoice(id: "a", title: "MacBook", isSelected: true), PillMenuChoice(id: "b", title: "External", isSelected: false)] }
        pill.menuActions.languages = { [PillMenuChoice(id: "auto", title: "Auto", isSelected: true), PillMenuChoice(id: "ru", title: "Русский", isSelected: false)] }

        // Fake mic level, ~7 samples a second.
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.14, repeats: true) { _ in
            Task { @MainActor in
                let v: Float = Float.random(in: 0...1) < 0.22 ? Float.random(in: 0...0.15) : Float.random(in: 0.3...1)
                pill.setLevel(v)
            }
        })

        if let held = steps.first(where: { $0.name == mode }) {
            held.run(pill, toast, lang)
            return
        }
        let counter = Counter()
        counter.next(pill, toast, lang)
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in counter.next(pill, toast, lang) }
        })
    }
}
