// The whole dictation path (spec 2.5): key → mic → recognition → cleanup → insert → history.
// Pure orchestration over injected parts, so the integration test runs with fakes and no system access.
import Foundation
import os

/// What the pill and toasts should show. The app maps these to PillController / ToastController.
public enum DictationEvent: Sendable, Equatable {
    case listening(confirmed: Bool)
    case handsFree
    case level(Float)
    case processing
    case idle
    case inserted
    case copiedOnly            // went to another window: text is on the clipboard
    case notInserted           // app did not take the text in 500 ms
    case secureInput           // password field: dictation unavailable
    case micSilent             // first 5 s gave zero level
    case longRecordingWarning  // 19th minute
    case failed(STTError)
}

/// Mic abstraction (MicRecorder conforms).
public protocol DictationMic: AnyObject, Sendable {
    func start(onChunk: (@Sendable (AudioChunk) -> Void)?, onLevel: (@Sendable (Float) -> Void)?,
               onMicConfirmed: (@Sendable () -> Void)?) throws
    func stop() -> MicRecording
}

/// Insert abstraction (Inserter conforms on macOS).
public protocol DictationInserter: Sendable {
    func insert(text: String, expected: ContextSnapshot?, current: ContextSnapshot?) async -> DictationInsertOutcome
    func pressReturn()
}

public enum DictationInsertOutcome: Sendable, Equatable {
    case inserted(takenAt: TimeInterval)
    case copiedOnly
    case notInserted
}

/// Text after recognition: rules + editor by style. Returned by the cleanup closure.
public struct CleanedText: Sendable, Equatable {
    public var text: String
    public var pressEnter: Bool
    public var styleId: String?
    public var editorModel: String?
    public var costUSD: Double?
    public init(text: String, pressEnter: Bool = false, styleId: String? = nil, editorModel: String? = nil, costUSD: Double? = nil) {
        self.text = text; self.pressEnter = pressEnter; self.styleId = styleId; self.editorModel = editorModel; self.costUSD = costUSD
    }
}

/// Cancel request for the dictation that is past the microphone stage (recognition, cleanup).
final class ProcessingCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var requested = false
    func begin() { lock.withLock { active = true; requested = false } }
    func end() { lock.withLock { active = false; requested = false } }
    /// Ignored when nothing is being processed (the normal cancel path handles a live recording).
    func requestCancel() { lock.withLock { if active { requested = true } } }
    var cancelled: Bool { lock.withLock { requested } }
}

public struct DictationDependencies: Sendable {
    public var mic: any DictationMic
    public var stt: @Sendable () -> any SpeechToText              // read per dictation: provider switch without restart (Р9)
    public var sttOptions: @Sendable (ContextSnapshot?) async -> STTOptions
    public var cleanup: @Sendable (String, ContextSnapshot?) async -> CleanedText
    public var inserter: any DictationInserter
    public var snapshot: @Sendable () -> ContextSnapshot
    public var currentFocus: @Sendable () -> ContextSnapshot
    public var secureInputActive: @Sendable () -> Bool
    public var history: HistoryStore
    /// Moves the temp WAV into the data folder (and converts it to m4a); returns the stored relative path.
    public var storeAudio: @Sendable (_ wav: URL, _ id: String, _ date: Date) async -> String?
    public var clock: any SusuClock
    public var onEvent: @Sendable (DictationEvent) -> Void
    /// After a successful insert: (dictation id, inserted text) — the edit watcher starts here (T2.7).
    public var onInserted: @Sendable (String, String) -> Void = { _, _ in }
    /// The history record could not be written: the app keeps a recovery copy so the text and the
    /// link to its audio are not lost (mandate, section 8).
    public var onSaveFailed: @Sendable (Dictation, Error) -> Void = { _, _ in }

    public init(mic: any DictationMic, stt: @escaping @Sendable () -> any SpeechToText,
                sttOptions: @escaping @Sendable (ContextSnapshot?) async -> STTOptions,
                cleanup: @escaping @Sendable (String, ContextSnapshot?) async -> CleanedText,
                inserter: any DictationInserter, snapshot: @escaping @Sendable () -> ContextSnapshot,
                currentFocus: @escaping @Sendable () -> ContextSnapshot, secureInputActive: @escaping @Sendable () -> Bool,
                history: HistoryStore, storeAudio: @escaping @Sendable (URL, String, Date) async -> String?,
                clock: any SusuClock = SystemClock(), onEvent: @escaping @Sendable (DictationEvent) -> Void) {
        self.mic = mic; self.stt = stt; self.sttOptions = sttOptions; self.cleanup = cleanup
        self.inserter = inserter; self.snapshot = snapshot; self.currentFocus = currentFocus
        self.secureInputActive = secureInputActive; self.history = history; self.storeAudio = storeAudio
        self.clock = clock; self.onEvent = onEvent
    }
}

/// Feed it hotkey actions in order (`send`). One dictation at a time.
/// Hotkey actions and mic chunks go through one ordered stream, so audio never reorders.
public actor DictationController {
    private enum Input: Sendable {
        case action(HotkeyAction, TimeInterval)
        case chunk(AudioChunk, ObjectIdentifier)
        case micConfirmed(ObjectIdentifier)
    }

    private let deps: DictationDependencies
    private let inputs: AsyncStream<Input>.Continuation
    private var current: Recording?
    private let processing = ProcessingCancel()
    public private(set) var lastText: String?

    /// Max length (spec 1.4): warning at 19 min, stop and insert at 20.
    static let warnAfterMs = 19 * 60_000
    static let stopAfterMs = 20 * 60_000
    static let silenceCheckMs = 5000
    static let timing = Logger(subsystem: "app.susu", category: "timing")

    private final class Recording: @unchecked Sendable {   // touched only on the actor
        let id = UUID().uuidString
        let startedAt = Date()
        var context: ContextSnapshot?
        var mode: DictationMode = .hold
        var stt: (any SpeechToText)?
        var session: (any STTSession)?
        var beginError: STTError?
        var buffered: [AudioChunk] = []   // audio before the hold is confirmed (Д9: first syllable is kept)
        var appended = 0                  // chunks handed to the session or buffer
        var receivedMs = 0
        var maxAbs = 0
        var micConfirmed = false
        var warned = false
    }

    public init(_ deps: DictationDependencies) {
        self.deps = deps
        let (stream, cont) = AsyncStream<Input>.makeStream()
        inputs = cont
        Task { [weak self] in
            for await input in stream { await self?.handle(input) }
        }
    }

    /// Thread-safe entry point for the hotkey callback. `t` = event time (uptime s).
    public nonisolated func send(_ action: HotkeyAction, at t: TimeInterval) {
        // An explicit cancel must reach a dictation that is already being recognized: the ordered
        // stream is busy with it, so the request is flagged here and checked before insertion.
        if case .cancel(.escape) = action { processing.requestCancel() }
        inputs.yield(.action(action, t))
    }

    private func handle(_ input: Input) async {
        switch input {
        case .action(let action, let t):
            switch action {
            case .startMic: startMic()
            case .confirmDictation: await confirm(mode: .hold)
            case .startHandsFree: await confirm(mode: .handsfree)
            case .finish: await finish(releasedAt: t)
            case .cancel(let reason): await cancel(reason)
            }
        case .chunk(let chunk, let owner):
            guard let rec = current, ObjectIdentifier(rec) == owner else { return }
            await received(chunk, rec)
        case .micConfirmed(let owner):
            guard let rec = current, ObjectIdentifier(rec) == owner else { return }
            rec.micConfirmed = true
            deps.onEvent(.listening(confirmed: true))
        }
    }

    private func startMic() {
        Self.timing.notice("start")
        if let old = current { old.session?.cancel(); _ = deps.mic.stop(); current = nil }
        if deps.secureInputActive() { Self.timing.notice("dropped: secure input"); deps.onEvent(.secureInput); return }
        let rec = Recording()
        let owner = ObjectIdentifier(rec)
        let stt = deps.stt()
        rec.stt = stt
        Task { await stt.prewarm() }
        let inputs = self.inputs
        do {
            try deps.mic.start(
                onChunk: { inputs.yield(.chunk($0, owner)) },
                onLevel: { [deps] in deps.onEvent(.level($0)) },
                onMicConfirmed: { inputs.yield(.micConfirmed(owner)) })
        } catch {
            Self.timing.notice("dropped: mic start \(String(describing: error), privacy: .public)")
            deps.onEvent(.failed(.badResponse("mic: \(error)")))
            return
        }
        current = rec
        rec.context = deps.snapshot()
    }

    private func append(_ chunk: AudioChunk, _ rec: Recording) {
        rec.appended += 1
        if let s = rec.session { s.append(chunk) } else { rec.buffered.append(chunk) }
    }

    private func received(_ chunk: AudioChunk, _ rec: Recording) async {
        let before = rec.receivedMs
        rec.receivedMs += chunk.durationMs
        append(chunk, rec)
        if before < Self.silenceCheckMs {
            for s in chunk.samples { rec.maxAbs = max(rec.maxAbs, abs(Int(s))) }
            // No signal at all in the first 5 s → stop, nothing saved (spec 1.4).
            if rec.receivedMs >= Self.silenceCheckMs, rec.maxAbs <= 1 {
                Self.timing.notice("dropped: mic silent")
                rec.session?.cancel()
                _ = deps.mic.stop()
                current = nil
                deps.onEvent(.micSilent)
                deps.onEvent(.idle)
                return
            }
        }
        if rec.receivedMs >= Self.warnAfterMs, !rec.warned { rec.warned = true; deps.onEvent(.longRecordingWarning) }
        if rec.receivedMs >= Self.stopAfterMs { await finish(releasedAt: deps.clock.now()) }
    }

    private func confirm(mode: DictationMode) async {
        guard let rec = current, rec.session == nil, rec.beginError == nil else { return }
        rec.mode = mode
        deps.onEvent(mode == .handsfree ? .handsFree : .listening(confirmed: rec.micConfirmed))
        var options = await deps.sttOptions(rec.context)
        let detector = LockedPause()
        options.pauseEnded = { detector.feed($0) }
        do {
            let session = try await (rec.stt ?? deps.stt()).begin(options)
            guard current === rec else { session.cancel(); return }
            for c in rec.buffered { session.append(c) }
            rec.buffered.removeAll()
            rec.session = session
        } catch {
            // e.g. no key: keep listening so the release is handled; finish() reports it.
            rec.beginError = (error as? STTError) ?? .badResponse("\(error)")
        }
    }

    private func finish(releasedAt t0: TimeInterval) async {
        guard let rec = current else { return }
        current = nil
        processing.begin()
        defer { processing.end() }
        let recording = deps.mic.stop()
        // The mic flushes its last chunk during stop(); those may still sit in the stream behind us.
        for c in recording.chunks.dropFirst(rec.appended) { append(c, rec) }
        deps.onEvent(.processing)
        var dictation = Dictation(id: rec.id, createdAt: rec.startedAt, durationMs: recording.durationMs, mode: rec.mode,
                                  appName: rec.context?.appName, bundleId: rec.context?.bundleID,
                                  windowTitle: rec.context?.windowTitle, url: rec.context?.url)
        if let wav = recording.wavURL { dictation.audioPath = await deps.storeAudio(wav, rec.id, rec.startedAt) }
        do {
            guard let session = rec.session else { throw rec.beginError ?? STTError.cancelled }
            let tSTT = deps.clock.now()
            let transcript = try await session.finish()
            let tClean = deps.clock.now()
            dictation.rawText = transcript.text
            dictation.sttProvider = transcript.provider.rawValue
            dictation.sttModel = transcript.model
            dictation.language = transcript.language
            dictation.fallbackUsed = rec.stt.map { transcript.provider != $0.id } ?? false
            let cleaned = await deps.cleanup(transcript.text, rec.context)
            let tInsert = deps.clock.now()
            defer {
                let ms = { (a: TimeInterval, b: TimeInterval) in Int(((b - a) * 1000).rounded()) }
                let tEnd = deps.clock.now()
                Self.timing.info("timing audio=\(recording.durationMs)ms release→stt=\(ms(t0, tSTT)) stt=\(ms(tSTT, tClean)) cleanup=\(ms(tClean, tInsert)) insert=\(ms(tInsert, tEnd)) editor=\(cleaned.editorModel ?? "-", privacy: .public)")
            }
            dictation.finalText = cleaned.text
            dictation.styleId = cleaned.styleId
            dictation.editorModel = cleaned.editorModel
            dictation.costUsd = cleaned.costUSD
            if cleaned.text.isEmpty {
                dictation.status = .failed
            } else if processing.cancelled {
                // Cancelled while recognizing: the text stays in history, nothing is pasted.
                Self.timing.notice("cancel: during processing")
                dictation.status = .cancelled
            } else {
                switch await deps.inserter.insert(text: cleaned.text, expected: rec.context, current: deps.currentFocus()) {
                case .inserted(let t1):
                    dictation.status = .inserted
                    dictation.latencyMs = max(0, Int(((t1 - t0) * 1000).rounded()))
                    if cleaned.pressEnter { deps.inserter.pressReturn() }
                    deps.onEvent(.inserted)
                    deps.onInserted(rec.id, cleaned.text)
                case .copiedOnly:
                    dictation.status = .copiedOnly; deps.onEvent(.copiedOnly)
                case .notInserted:
                    dictation.status = .notInserted; deps.onEvent(.notInserted)
                }
                lastText = cleaned.text
            }
        } catch {
            dictation.status = .failed
            deps.onEvent(.failed((error as? STTError) ?? .badResponse("\(error)")))
        }
        await Self.persist(dictation, save: { [history = deps.history] in try await history.save($0) }, onFailed: deps.onSaveFailed)
        deps.onEvent(.idle)
    }

    /// Saves the record; a failure is logged and handed to `onFailed` instead of being dropped.
    static func persist(_ dictation: Dictation, save: @Sendable (Dictation) async throws -> Void,
                        onFailed: @Sendable (Dictation, Error) -> Void) async {
        do { try await save(dictation) } catch {
            timing.error("history save failed for \(dictation.id, privacy: .public): \(String(describing: error), privacy: .public)")
            onFailed(dictation, error)
        }
    }

    private func cancel(_ reason: HotkeyCancelReason) async {
        guard let rec = current else { return }
        // ponytail: notice (not info) so the reason survives in the log for E2E post-mortems.
        Self.timing.notice("cancel: \(String(describing: reason), privacy: .public)")
        current = nil
        rec.session?.cancel()
        let recording = deps.mic.stop()
        deps.onEvent(.idle)
        // Esc keeps the audio with status «отменено» (spec 1.3); combos and short taps leave no trace.
        guard reason == .escape, rec.session != nil || rec.beginError != nil else {
            if let wav = recording.wavURL { try? FileManager.default.removeItem(at: wav) }
            return
        }
        var d = Dictation(id: rec.id, createdAt: rec.startedAt, durationMs: recording.durationMs, mode: rec.mode,
                          status: .cancelled, appName: rec.context?.appName, bundleId: rec.context?.bundleID,
                          windowTitle: rec.context?.windowTitle, url: rec.context?.url)
        if let wav = recording.wavURL { d.audioPath = await deps.storeAudio(wav, rec.id, rec.startedAt) }
        await Self.persist(d, save: { [history = deps.history] in try await history.save($0) }, onFailed: deps.onSaveFailed)
    }
}

/// PauseDetector is a mutating struct; the STT session calls it from its own thread.
private final class LockedPause: @unchecked Sendable {
    private var detector = PauseDetector()
    private let lock = NSLock()
    func feed(_ chunk: AudioChunk) -> Bool { lock.withLock { detector.feed(chunk) } }
}
