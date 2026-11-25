// State machine of the first-run wizard. Every step is skippable; nothing here blocks the app.
import SwiftUI
import SusuCore

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Equatable { case permissions, how, trial, wispr, finish }
    enum Mode { case cloud, keys, mac }
    enum KeyResult: Equatable { case none, checking, works, wrong, noMoney, offline, empty, other(String) }
    enum MacState: Equatable { case idle, downloading(Double), done, failed }
    enum WisprState: Equatable { case found, loading, dry(WisprPreview), noSpace(WisprPreview), importing(Double), done(WisprPreview), failed }

    let services: AppServices
    let hooks: OnboardingHooks
    let system: OnboardingSystem
    var onFinish: (_ openHistory: Bool) -> Void = { _ in }

    @Published var step: Step = .permissions
    @Published var mic: MicPermission
    @Published var axTrusted: Bool
    @Published var axRequested = false
    @Published var choice: Mode = .keys
    @Published var groqKey = ""
    @Published var openRouterKey = ""
    @Published var keyResults: [ProviderID: KeyResult] = [:]
    @Published var mac: MacState = .idle
    @Published var trialText = ""
    @Published var phraseIndex = Int.random(in: 0..<3)
    @Published var wispr: WisprState = .found
    @Published var skipped: Set<Step> = []
    let wisprFound: Bool
    private var pollTask: Task<Void, Never>?
    private var work: Task<Void, Never>?

    init(services: AppServices, hooks: OnboardingHooks, system: OnboardingSystem) {
        self.services = services; self.hooks = hooks; self.system = system
        mic = system.micPermission(); axTrusted = system.axTrusted()
        wisprFound = system.wisprFolderExists()
        startPolling()
    }

    deinit { pollTask?.cancel(); work?.cancel() }

    var steps: [Step] { wisprFound ? [.permissions, .how, .trial, .wispr] : [.permissions, .how, .trial] }
    var stepNumber: Int { (steps.firstIndex(of: step) ?? steps.count - 1) + 1 }
    var trialDone: Bool { !trialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var language: InterfaceLanguage { services.settings.current.interfaceLanguage }

    /// «⌃», «правый ⌃», «⌃Space»: the configured dictation key.
    func dictationKeyName(_ lang: InterfaceLanguage) -> String {
        let k = services.settings.current.hotkeys.dictation
        func glyph(_ m: ModifierKey) -> String {
            switch m {
            case .leftControl, .rightControl: "⌃"
            case .leftOption, .rightOption: "⌥"
            case .leftCommand, .rightCommand: "⌘"
            case .leftShift, .rightShift: "⇧"
            case .fn: "fn"
            }
        }
        if let m = k.modifierKey {
            let g = glyph(m)
            return m.rawValue.hasPrefix("right") ? ONS.string("ob.try.keyRight", lang, g) : g
        }
        let mods = k.modifiers.map { ["control": "⌃", "option": "⌥", "command": "⌘", "shift": "⇧"][$0.rawValue] ?? "" }.joined()
        let names = [49: "Space", 79: "F18", 80: "F19", 36: "↩"]
        return mods + (k.keyCode.map { names[$0] ?? "#\($0)" } ?? "")
    }

    /// The Ctrl+Space hint only matters while hands-free is on that chord.
    var showCtrlSpaceHint: Bool {
        let h = services.settings.current.hotkeys
        return h.handsFreeChordEnabled && h.handsFreeChord.keyCode == 49 && h.handsFreeChord.modifiers == [.control]
    }

    // MARK: Navigation

    func skip() { skipped.insert(step); advance() }

    func advance() {
        let list = steps
        if step == .how {
            // A key that could not be stored must not look saved: stay on the step and show why.
            guard saveKeys() else { return }
            // The choice must reach the settings the recognizer reads: "Mac only" picked here
            // would otherwise still send audio to the cloud.
            let mode: WorkMode = switch choice { case .cloud: .cloud; case .keys: .ownKeys; case .mac: .macOnly }
            // Fail closed: if the mode cannot be saved the wizard stays here rather than dictating
            // under a mode the user did not pick.
            do { _ = try services.settings.update { $0.preferences.workMode = mode } } catch { return }
        }
        guard let i = list.firstIndex(of: step) else { return }
        step = i + 1 < list.count ? list[i + 1] : .finish
    }

    func back() { if let i = steps.firstIndex(of: step), i > 0 { step = steps[i - 1] } }

    func finish(openHistory: Bool) {
        work?.cancel()
        onFinish(openHistory)
    }

    // MARK: Permissions

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                let m = system.micPermission(), a = system.axTrusted()
                if m != mic { mic = m }
                if a != axTrusted { axTrusted = a }
            }
        }
    }

    func askMic() {
        Task {
            _ = await system.requestMic()
            mic = system.micPermission()
        }
    }

    func askAccessibility() {
        axRequested = true
        system.promptAX()
        system.open(OnboardingSystem.axPane)
    }

    func openMicSettings() { system.open(OnboardingSystem.micPane) }
    func openKeyboardSettings() { system.open(OnboardingSystem.keyboardPane) }

    // MARK: Keys

    func key(for p: ProviderID) -> String { (p == .groq ? groqKey : openRouterKey).trimmingCharacters(in: .whitespacesAndNewlines) }

    func checkKey(_ p: ProviderID) {
        let k = key(for: p)
        guard !k.isEmpty else { keyResults[p] = .empty; return }
        keyResults[p] = .checking
        Task {
            let status = await KeyChecker(registry: services.registry).check(provider: p, key: k)
            // The field changed while the check was running: this answer is about another key.
            guard key(for: p) == k else { return }
            switch status {
            case .works:
                // "Works" only once the key is really stored: a key that is valid but not saved
                // would be gone on the next launch.
                do {
                    try services.secrets.set(k, for: p)
                    keyResults[p] = .works
                } catch {
                    keyResults[p] = .other("Keychain: \(error)")
                }
            case .wrongKey: keyResults[p] = .wrong
            case .noMoney: keyResults[p] = .noMoney
            case .noNetwork: keyResults[p] = .offline
            case .other(let s): keyResults[p] = .other(s)
            }
        }
    }

    /// Keys typed but never checked are still saved when the user moves on (they can fix them in Settings).
    /// Returns false when a key could not be stored; the reason is shown next to that key.
    private func saveKeys() -> Bool {
        guard choice == .keys else { return true }
        var saved = true
        for p in [ProviderID.groq, .openRouter] where !key(for: p).isEmpty && keyResults[p] != .works && keyResults[p] != .wrong {
            do { try services.secrets.set(key(for: p), for: p) } catch {
                keyResults[p] = .other("Keychain: \(error)")
                saved = false
            }
        }
        return saved
    }

    var hasKeys: Bool { [ProviderID.groq, .openRouter].contains { !key(for: $0).isEmpty } }

    // MARK: Mac only

    func startDownload() {
        guard let hook = hooks.downloadGigaAM else { return }
        mac = .downloading(0)
        work = Task { [weak self] in
            do {
                try await hook { p in Task { @MainActor in self?.mac = .downloading(p) } }
                self?.mac = .done
            } catch { if !Task.isCancelled { self?.mac = .failed } }
        }
    }

    func cancelDownload() { work?.cancel(); mac = .idle }

    // MARK: Wispr

    func dryRun() {
        guard let hook = hooks.wisprDryRun else { return }
        wispr = .loading
        Task {
            if let p = await hook() { wispr = p.neededBytes > p.freeBytes && p.freeBytes > 0 ? .noSpace(p) : .dry(p) }
            else { skip() }
        }
    }

    func startImport(includeAudio: Bool, preview: WisprPreview) {
        guard let hook = hooks.wisprImport else { return }
        wispr = .importing(0)
        work = Task { [weak self] in
            do {
                try await hook(includeAudio) { p in Task { @MainActor in self?.wispr = .importing(p) } }
                self?.wispr = .done(preview)
            } catch { if !Task.isCancelled { self?.wispr = .failed } }
        }
    }
}
