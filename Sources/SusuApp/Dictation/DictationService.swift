// Wires the dictation path into the running app: KeyTap → DictationController → real mic, STT, insert, history.
import AppKit
import AVFoundation
import os
import SusuCore

extension MicRecorder: DictationMic {}

/// Notes key (T3.10): the text goes into a new note, not into the field. Title and tags come from the editor model.
private struct NoteInserter: DictationInserter {
    let services: AppServices
    let onSaved: @Sendable (String) -> Void
    func insert(text: String, expected: ContextSnapshot?, current: ContextSnapshot?) async -> DictationInsertOutcome {
        let s = services
        let store = NotesStore(database: s.database, baseDirectory: s.dataDirectory)
        guard let note = try? await store.create(text: text) else { return .notInserted }
        onSaved(note.id)
        let choice = s.settings.current.providers.editor ?? DictationService.defaultEditor
        // "Mac only": the note keeps its plain first-words title instead of asking a cloud model.
        guard CloudPolicy.allowsLLM(workMode: s.settings.current.preferences.workMode,
                                    baseURL: choice.baseURL ?? s.registry.info(for: choice.providerID)?.baseURL) else {
            return .inserted(takenAt: SystemClock().now())
        }
        let chat = SpendRecordingChat(DictationService.editorChat(choice, secrets: s.secrets, registry: s.registry),
                                      provider: choice.providerID, log: s.spend)
        Task { _ = try? await store.autoTitle(id: note.id, titler: NoteTitler(llm: chat, model: choice.model)) }
        return .inserted(takenAt: SystemClock().now())
    }
    func pressReturn() {}
}

private struct SystemInserter: DictationInserter {
    let inserter = Inserter()
    func insert(text: String, expected: ContextSnapshot?, current: ContextSnapshot?) async -> DictationInsertOutcome {
        let r = await inserter.insert(text: text, expected: expected, current: current)
        switch r.status {
        case .inserted: return .inserted(takenAt: r.takenAt ?? SystemClock().now())
        case .copiedOnly:
            DictationService.log.info("copied only: expected \(expected?.bundleID ?? "-", privacy: .public) pid=\(expected?.pid ?? -1) el=\(expected?.focusedElementID ?? "-", privacy: .public) now \(current?.bundleID ?? "-", privacy: .public) pid=\(current?.pid ?? -1) el=\(current?.focusedElementID ?? "-", privacy: .public)")
            return .copiedOnly
        case .notInserted: return .notInserted
        }
    }
    func pressReturn() { inserter.pressReturn() }
}

@MainActor
final class DictationService {
    nonisolated static let log = Logger(subsystem: "app.susu", category: "dictation")
    /// No lead-in (spec 3.3). The English one ("Work dictation with product names:") lifted names on the test set,
    /// but with a near-empty dictionary Whisper took it as the language and translated Russian speech into English
    /// (first live dictations, 24.11). Names come from the dictionary terms alone.
    nonisolated static let leadIn: String? = nil

    let services: AppServices
    private var tap: KeyTap?
    private var tapRunning = false
    private let paused = LockedFlag()
    private var observers: [NSObjectProtocol] = []
    private(set) var controller: DictationController?
    private var notesController: DictationController?
    /// Events of the notes key (pill shows «заметка»); `.inserted` means a note was saved.
    var onNoteEvent: (DictationEvent) -> Void = { _ in }
    private let gigaAM = LockedSTT()
    /// Called with the trigger glyph whenever the hotkey is (re)installed.
    var onKeyName: (String) -> Void = { _ in }
    /// Ctrl+Cmd+C put the last text on the clipboard.
    var onCopied: () -> Void = {}
    /// The edit watcher added dictionary entries.
    var onLearned: ([DictionaryEntry]) -> Void = { _ in }
    var onEvent: (DictationEvent) -> Void = { DictationService.log.info("event \(String(describing: $0), privacy: .public)") }

    init(services: AppServices) { self.services = services }

    /// Starts listening to the hotkey. Returns false without Input Monitoring / Accessibility permission.
    @discardableResult
    func start() -> Bool {
        let s = services
        let secrets = s.secrets
        // ponytail: dev builds fall back to GROQ_API_KEY from the environment when Keychain has no key.
        let groq = OpenAICompatibleTranscription.groq(keyProvider: {
            (try? secrets.get(.groq)) ?? ProcessInfo.processInfo.environment["GROQ_API_KEY"]
        })
        let gigaAM = self.gigaAM
        loadGigaAMIfPresent()
        let onEvent: @Sendable (DictationEvent) -> Void = { [weak self] e in
            if case .level = e {} else { Self.log.info("event \(String(describing: e), privacy: .public)") }
            Task { @MainActor in self?.onEvent(e) }
        }
        let onInserted: @Sendable (String, String) -> Void = { [weak self] id, text in
            Task { @MainActor in
                guard let self else { return }
                EditWatcher.watch(id: id, inserted: text, services: s) { [weak self] in self?.onLearned($0) }
            }
        }
        let audioRoot = s.dataDirectory.appendingPathComponent("audio", isDirectory: true)
        let modelsRoot = s.dataDirectory.appendingPathComponent("models")
        var deps = DictationDependencies(
            mic: ProcessInfo.processInfo.environment["SUSU_E2E_AUDIO"].map { FileMic(path: $0) as any DictationMic }
                ?? MicRecorder(devicePriority: s.settings.current.micPriority),
            stt: {
                // Read per dictation: the model the wizard just downloaded works without a restart,
                // and "Mac only" never reaches the cloud even when a Groq key is stored.
                if gigaAM.value == nil { gigaAM.value = Self.loadGigaAM(modelsRoot: modelsRoot) }
                let settings = s.settings.current
                return STTSelection.make(workMode: settings.preferences.workMode, choice: settings.providers.dictation,
                                         cloud: groq, local: gigaAM.value)
            },
            sttOptions: { context in
                let terms = (try? await s.dictionary.hintTerms()) ?? []
                let hint = STTHintBuilder.build(terms: terms.map { HintTerm($0) }, windowTitle: context?.windowTitle,
                                                leadIn: Self.leadIn)
                return STTOptions(language: s.settings.current.dictationLanguage.languageMode, hint: hint, context: context)
            },
            cleanup: { text, context in await Self.cleanup(text, context: context, services: s) },
            inserter: SystemInserter(),
            snapshot: { ContextSnapshotter.snapshot(exclusions: Set(s.settings.current.preferences.contextExclusions)) },
            currentFocus: { ContextSnapshotter.currentFocus() },
            secureInputActive: { KeyTap.secureInputActive },
            history: s.history,
            storeAudio: { wav, id, date in Self.storeAudio(wav: wav, id: id, date: date, root: audioRoot) },
            onEvent: onEvent)
        deps.onInserted = onInserted
        let recoveryRoot = s.dataDirectory.appendingPathComponent("recovery", isDirectory: true)
        deps.onSaveFailed = { dictation, _ in Self.writeRecovery(dictation, root: recoveryRoot) }
        let controller = DictationController(deps)
        self.controller = controller
        // ponytail: notes also land in dictation history (one record per note); a separate flag if that bothers.
        var noteDeps = deps
        noteDeps.mic = MicRecorder(devicePriority: s.settings.current.micPriority)
        noteDeps.inserter = NoteInserter(services: s, onSaved: { _ in })
        noteDeps.onInserted = { _, _ in }
        noteDeps.onEvent = { [weak self] e in Task { @MainActor in self?.onNoteEvent(e) } }
        notesController = DictationController(noteDeps)
        let ok = installHotkey()
        // First run: the tap cannot start before the user grants the permission in the wizard.
        // Keep trying once a second until it does, so dictation works without a restart.
        if !ok {
            Task { [weak self] in
                while let self, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    // Someone else (settings change, wake) may have installed a working tap meanwhile:
                    // replacing it could cut a recording in progress.
                    if self.tapRunning || self.installHotkey() { break }
                }
            }
        }
        // Recording a shortcut in Settings must not start a dictation (T3.6).
        observers.append(NotificationCenter.default.addObserver(forName: .susuShortcutRecording, object: nil, queue: .main) { [weak self] n in
            let active = n.userInfo?["active"] as? Bool ?? false
            MainActor.assumeIsolated { self?.paused.value = active }
        })
        // After sleep the tap can come back dead; a fresh one is cheap (Д20).
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.installHotkey() }
        })
        // A changed hotkey applies without restart.
        Task { [weak self] in
            var last = s.settings.current.hotkeys
            for await settings in s.settings.changes() where settings.hotkeys != last {
                last = settings.hotkeys
                self?.installHotkey()
            }
        }
        return ok
    }

    @discardableResult
    private func installHotkey() -> Bool {
        guard let controller else { return false }
        tap?.stop()
        let hk = services.settings.current.hotkeys
        let config = HotkeyConfig(trigger: Self.trigger(hk), holdThreshold: hk.holdThreshold,
                                  doubleTapWindow: hk.doubleTapWindow, allowHandsFree: true)
        let clock = SystemClock()
        let paused = self.paused
        let tap = KeyTap()
        tap.register(HotkeyController(config: config) { action in
            if case .startMic = action, paused.value { return }
            Self.log.info("hotkey \(String(describing: action), privacy: .public)")
            controller.send(action, at: clock.now())
        })
        if let notes = notesController, let noteTrigger = Self.trigger(hk.notes), noteTrigger.keyCode != config.trigger.keyCode {
            let noteConfig = HotkeyConfig(trigger: noteTrigger, holdThreshold: hk.holdThreshold,
                                          doubleTapWindow: hk.doubleTapWindow, allowHandsFree: false)
            tap.register(HotkeyController(config: noteConfig) { action in
                if case .startMic = action, paused.value { return }
                notes.send(action, at: clock.now())
            })
        }
        // Global Ctrl+Cmd+V / Ctrl+Cmd+C (spec 1.3): paste or copy the last dictation.
        for (setting, paste) in [(hk.pasteLast, true), (hk.copyLast, false)] {
            guard let code = setting.keyCode else { continue }
            tap.registerChord(keyCode: UInt16(code), modifiers: setting.modifiers) { [weak self] in
                Task { @MainActor in paste ? self?.pasteLast() : self?.copyLast() }
            }
        }
        self.tap = tap
        onKeyName(Self.keyName(config.trigger))
        let ok = tap.start()
        tapRunning = ok
        Self.log.info("hotkey tap started: \(ok, privacy: .public) ax=\(AXIsProcessTrusted(), privacy: .public) listen=\(CGPreflightListenEventAccess(), privacy: .public) post=\(CGPreflightPostEventAccess(), privacy: .public) mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue, privacy: .public)")
        return ok
    }

    /// Pill buttons for hands-free mode.
    func finishHandsFree() { for c in [controller, notesController] { c?.send(.finish, at: SystemClock().now()) } }
    func cancelHandsFree() { for c in [controller, notesController] { c?.send(.cancel(.escape), at: SystemClock().now()) } }

    /// Mic button on the Notes screen: a hands-free note, finished from the pill.
    func startVoiceNote() {
        let t = SystemClock().now()
        notesController?.send(.startMic, at: t)
        notesController?.send(.startHandsFree, at: t)
    }

    func paste(_ text: String) {
        Task { _ = await SystemInserter().insert(text: text, expected: nil, current: ContextSnapshotter.currentFocus()) }
    }

    func copyLast() {
        guard let controller else { return }
        Task {
            guard let text = await controller.lastText else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            onCopied()
        }
    }

    func pasteLast() {
        guard let controller else { return }
        Task {
            guard let text = await controller.lastText else { return }
            _ = await SystemInserter().insert(text: text, expected: nil, current: ContextSnapshotter.currentFocus())
        }
    }

    /// Trigger: SUSU_TRIGGER env (f18, rightControl, …) for tests, else the dictation key from settings.
    static func trigger(_ hotkeys: HotkeySettings) -> HotkeyTrigger {
        if let name = ProcessInfo.processInfo.environment["SUSU_TRIGGER"], let t = trigger(named: name) { return t }
        return trigger(hotkeys.dictation) ?? .leftControl
    }

    static func keyName(_ t: HotkeyTrigger) -> String {
        [59: "⌃", 62: "⌃", 58: "⌥", 61: "⌥", 55: "⌘", 54: "⌘", 79: "F18", 80: "F19", 49: "Space"][Int(t.keyCode)] ?? "#\(t.keyCode)"
    }

    static func trigger(named name: String) -> HotkeyTrigger? {
        if name == "f18" { return .f18 }
        return ModifierKey(rawValue: name).flatMap { trigger(HotkeySetting(modifierKey: $0)) }
    }

    static func trigger(_ setting: HotkeySetting?) -> HotkeyTrigger? {
        guard let setting else { return nil }
        if let key = setting.modifierKey {
            switch key {
            case .leftControl: return .leftControl
            case .rightControl: return .rightControl
            case .leftOption: return .leftOption
            case .rightOption: return .rightOption
            case .leftCommand: return .leftCommand
            case .rightCommand: return .rightCommand
            case .leftShift, .rightShift, .fn: return nil   // ponytail: not offered as triggers yet
            }
        }
        guard let code = setting.keyCode else { return nil }
        let flags: [HotkeyModifier: UInt64] = [.control: 0x40000, .option: 0x80000, .command: 0x100000, .shift: 0x20000]
        return HotkeyTrigger.key(UInt16(code), modifiers: setting.modifiers.reduce(0) { $0 | (flags[$1] ?? 0) })
    }

    private func loadGigaAMIfPresent() {
        gigaAM.value = Self.loadGigaAM(modelsRoot: services.dataDirectory.appendingPathComponent("models"))
    }

    nonisolated static func loadGigaAM(modelsRoot: URL) -> (any SpeechToText)? {
        let dir = ModelDownloader(modelsRoot: modelsRoot).gigaAMDirectory
        guard GigaAMModelFiles.isPresent(in: dir) else { return nil }
        return GigaAMSpeechToText(local: GigaAMLocal(modelDir: dir))
    }

    /// Provisional default editor (T2.5 bench, gates not met, the founder decides): Groq qwen3.8-27b, no reasoning.
    nonisolated static let defaultEditor = ProviderChoice(providerID: .groq, model: "qwen/qwen3.8-27b")

    /// Step 1 rules, step 2 LLM editor by the style's level (spec 3.4).
    nonisolated static func cleanup(_ text: String, context: ContextSnapshot?, services s: AppServices) async -> CleanedText {
        let styles = (try? await s.styles.styles()) ?? []
        let rules = (try? await s.styles.rules()) ?? []
        let style = styles.isEmpty ? nil : StyleResolver.resolve(context: context, styles: styles, rules: rules)
        return await cleanup(text, style: style, context: context, services: s)
    }

    /// Same, with the style already chosen (also used by the Styles preview).
    nonisolated static func cleanup(_ text: String, style: Style?, context: ContextSnapshot?, services s: AppServices) async -> CleanedText {
        let replacements = ((try? await s.dictionary.replacements()) ?? []).map { RulesEntry(phrase: $0.phrase, replacement: $0.replacement) }
        let snippets = ((try? await s.dictionary.snippets()) ?? []).compactMap(RulesEntry.init)
        let step1 = CleanupRules.apply(text, options: RulesOptions(
            replacements: replacements, snippets: snippets, capitalize: style?.level != .verbatim,
            voiceCommandsEnabled: style?.voiceCommands ?? false))
        let level = style?.level ?? .normal
        guard level != .verbatim, !step1.text.isEmpty else {
            return CleanedText(text: step1.text, pressEnter: step1.pressEnter, styleId: style?.id)
        }
        let choice = s.settings.current.providers.editor ?? defaultEditor
        // "Mac only": no text leaves the Mac, so the editor runs only against a local model.
        guard CloudPolicy.allowsLLM(workMode: s.settings.current.preferences.workMode,
                                    baseURL: choice.baseURL ?? s.registry.info(for: choice.providerID)?.baseURL) else {
            return CleanedText(text: step1.text, pressEnter: step1.pressEnter, styleId: style?.id)
        }
        let result = await Editor.edit(
            text: step1.text, level: level,
            context: EditorContext(app: context?.appName, textBeforeCursor: context?.textBeforeCursor, styleRule: style?.prompt),
            terms: (try? await s.dictionary.hintTerms()) ?? [],
            examples: (try? await s.dictionary.editorExamples()) ?? [],
            chat: SpendRecordingChat(editorChat(choice, secrets: s.secrets, registry: s.registry), provider: choice.providerID, log: s.spend),
            model: choice.model)
        return CleanedText(text: result.text, pressEnter: step1.pressEnter, styleId: style?.id,
                           editorModel: result.usedModel ? result.model : nil, costUSD: result.costUSD)
    }

    nonisolated static func editorChat(_ choice: ProviderChoice, secrets: SecretStore, registry: ProviderRegistry) -> any ChatLLM {
        let id = choice.providerID
        let url = URL(string: choice.baseURL ?? registry.info(for: id)?.baseURL ?? "") ?? URL(string: "https://api.groq.com/openai/v1")!
        var profile: OpenAICompatibleChat.Profile = id == .openRouter ? .openRouter() : .generic
        // Fast answers: no hidden reasoning (measured in T2.5).
        if id == .groq { profile.extraBody["reasoning_effort"] = .string(choice.model.contains("gpt-oss") ? "low" : "none") }
        let envName = id == .groq ? "GROQ_API_KEY" : "OPENROUTER_API_KEY"
        return OpenAICompatibleChat(baseURL: url, apiKey: { (try? secrets.get(id)) ?? ProcessInfo.processInfo.environment[envName] },
                                    profile: profile)
    }

    /// Recovery copy of a dictation the database refused: recovery/<id>.json in the data folder.
    @discardableResult
    nonisolated static func writeRecovery(_ dictation: Dictation, root: URL) -> URL? {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("\(dictation.id).json")
            try JSONEncoder().encode(dictation).write(to: file, options: .atomic)
            return file
        } catch {
            log.error("recovery copy failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Moves the temp WAV to audio/yyyy-MM/<id>.m4a in the data folder; returns the path relative to it.
    /// The recording is never thrown away: if conversion fails the WAV itself is kept next to the m4a files,
    /// and if even that fails the temp file stays where it is.
    nonisolated static func storeAudio(wav: URL, id: String, date: Date, root: URL) -> String? {
        let fm = FileManager.default
        let month = date.formatted(.iso8601.year().month())
        let folder = root.appendingPathComponent(month)
        do {
            let data = try Data(contentsOf: wav)
            try WisprAudio.convertWAVToM4A(wav: data, workDirectory: fm.temporaryDirectory,
                                           to: folder.appendingPathComponent("\(id).m4a"))
            try? fm.removeItem(at: wav)
            return "audio/\(month)/\(id).m4a"
        } catch {
            log.error("m4a conversion failed, keeping the wav: \(String(describing: error), privacy: .public)")
        }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let kept = folder.appendingPathComponent("\(id).wav")
            try? fm.removeItem(at: kept)
            try fm.moveItem(at: wav, to: kept)
            return "audio/\(month)/\(id).wav"
        } catch {
            log.error("could not keep the wav, left at \(wav.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

private final class LockedSTT: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: (any SpeechToText)?
    var value: (any SpeechToText)? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
