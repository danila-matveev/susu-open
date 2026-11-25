import Foundation
import Testing
@testable import SusuCore

private final class DCBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func with<R>(_ f: (inout T) -> R) -> R { lock.withLock { f(&value) } }
    var get: T { lock.withLock { value } }
}

private final class DCMic: DictationMic, @unchecked Sendable {
    let onChunk = DCBox<(@Sendable (AudioChunk) -> Void)?>(nil)
    let sent = DCBox<[AudioChunk]>([])
    func start(onChunk: (@Sendable (AudioChunk) -> Void)?, onLevel: (@Sendable (Float) -> Void)?,
               onMicConfirmed: (@Sendable () -> Void)?) throws {
        sent.with { $0 = [] }
        self.onChunk.with { $0 = onChunk }
        onMicConfirmed?()
    }
    func push(_ n: Int, level: Int16 = 1000) {
        for _ in 0..<n {
            let c = AudioChunk(samples: Array(repeating: level, count: 640), startMs: sent.get.count * 40)
            sent.with { $0.append(c) }
            onChunk.get?(c)
        }
    }
    func stop() -> MicRecording {
        onChunk.with { $0 = nil }
        return MicRecording(chunks: sent.get, wavURL: nil)
    }
}

private struct DCSession: STTSession {
    let got: DCBox<[AudioChunk]>
    func append(_ chunk: AudioChunk) { got.with { $0.append(chunk) } }
    func finish() async throws -> Transcript {
        Transcript(text: "привет \(got.get.count)", provider: .groq, model: "fake", audioSeconds: 1, networkMs: 1)
    }
    func cancel() {}
    var partials: AsyncStream<String> { AsyncStream { $0.finish() } }
}

private struct DCSTT: SpeechToText {
    let got = DCBox<[AudioChunk]>([])
    var id: ProviderID { .groq }
    func prewarm() async {}
    func begin(_ options: STTOptions) async throws -> any STTSession { DCSession(got: got) }
}

private struct DCInserter: DictationInserter {
    let texts = DCBox<[String]>([])
    func insert(text: String, expected: ContextSnapshot?, current: ContextSnapshot?) async -> DictationInsertOutcome {
        texts.with { $0.append(text) }
        return .inserted(takenAt: 10.2)
    }
    func pressReturn() {}
}

private struct DCRig {
    let mic = DCMic()
    let stt = DCSTT()
    let inserter = DCInserter()
    let events = DCBox<[DictationEvent]>([])
    let history: HistoryStore
    let controller: DictationController

    init() throws {
        history = HistoryStore(database: try .inMemory())
        let (stt, events) = (self.stt, self.events)
        controller = DictationController(DictationDependencies(
            mic: mic, stt: { stt }, sttOptions: { _ in STTOptions() },
            cleanup: { text, _ in CleanedText(text: text) }, inserter: inserter,
            snapshot: { ContextSnapshot(appName: "TextEdit") }, currentFocus: { ContextSnapshot(appName: "TextEdit") },
            secureInputActive: { false }, history: history, storeAudio: { _, _, _ in nil },
            onEvent: { e in events.with { $0.append(e) } }))
    }

    /// Waits until the controller reports `idle` `count` times.
    func idle(_ count: Int = 1) async throws {
        for _ in 0..<200 where events.get.filter({ $0 == .idle }).count < count { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 30_000_000)
    }

    func saved() async throws -> [Dictation] { try await history.feed().days.flatMap(\.items) }
}

@Suite struct DictationControllerTests {
    /// Escape while the text is being cleaned up: nothing is pasted, the text stays in history.
    @Test func cancelDuringProcessingPreventsInsertion() async throws {
        let mic = DCMic(), stt = DCSTT(), inserter = DCInserter()
        let events = DCBox<[DictationEvent]>([])
        let history = HistoryStore(database: try .inMemory())
        let box = DCBox<DictationController?>(nil)
        let controller = DictationController(DictationDependencies(
            mic: mic, stt: { stt }, sttOptions: { _ in STTOptions() },
            cleanup: { text, _ in
                box.get?.send(.cancel(.escape), at: 2)   // the user cancels while cleanup runs
                return CleanedText(text: text)
            },
            inserter: inserter,
            snapshot: { ContextSnapshot(appName: "TextEdit") }, currentFocus: { ContextSnapshot(appName: "TextEdit") },
            secureInputActive: { false }, history: history, storeAudio: { _, _, _ in nil },
            onEvent: { e in events.with { $0.append(e) } }))
        box.with { $0 = controller }

        controller.send(.startMic, at: 1)
        controller.send(.confirmDictation, at: 1.3)
        try await Task.sleep(nanoseconds: 20_000_000)
        mic.push(10)
        controller.send(.finish, at: 1.5)
        for _ in 0..<200 where !events.get.contains(.idle) { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 30_000_000)

        #expect(inserter.texts.get.isEmpty)
        let rows = try await history.feed().days.flatMap(\.items)
        #expect(rows.count == 1)
        #expect(rows.first?.status == .cancelled)
        #expect(rows.first?.finalText == "привет 10")

        // The next dictation is not affected by the old cancel.
        controller.send(.startMic, at: 5)
        controller.send(.confirmDictation, at: 5.3)
        try await Task.sleep(nanoseconds: 20_000_000)
        box.with { $0 = nil }
        mic.push(3)
        controller.send(.finish, at: 5.5)
        for _ in 0..<200 where events.get.filter({ $0 == .idle }).count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(inserter.texts.get.count == 1)
    }

    @Test func holdAndReleaseInsertsOnceWithAllAudio() async throws {
        let rig = try DCRig()
        rig.controller.send(.startMic, at: 10)
        try await Task.sleep(nanoseconds: 20_000_000)
        rig.mic.push(5)                       // before the hold is confirmed: must not be lost
        rig.controller.send(.confirmDictation, at: 10.25)
        try await Task.sleep(nanoseconds: 20_000_000)
        rig.mic.push(20)
        rig.controller.send(.finish, at: 10.0)
        try await rig.idle()

        #expect(rig.inserter.texts.get == ["привет 25"])
        #expect(rig.stt.got.get == rig.mic.sent.get)   // same chunks, same order
        let rows = try await rig.saved()
        #expect(rows.count == 1)
        #expect(rows.first?.status == .inserted)
        #expect(rows.first?.latencyMs == 200)
        #expect(rows.first?.appName == "TextEdit")
        #expect(await rig.controller.lastText == "привет 25")
    }

    @Test func comboCancelLeavesNoTrace() async throws {
        let rig = try DCRig()
        rig.controller.send(.startMic, at: 1)
        rig.controller.send(.confirmDictation, at: 1.3)
        try await Task.sleep(nanoseconds: 20_000_000)
        rig.mic.push(10)
        rig.controller.send(.cancel(.combo), at: 1.5)
        try await rig.idle()
        #expect(rig.inserter.texts.get.isEmpty)
        #expect(try await rig.saved().isEmpty)
    }

    @Test func escapeKeepsCancelledRecord() async throws {
        let rig = try DCRig()
        rig.controller.send(.startMic, at: 1)
        rig.controller.send(.confirmDictation, at: 1.3)
        try await Task.sleep(nanoseconds: 20_000_000)
        rig.mic.push(10)
        rig.controller.send(.cancel(.escape), at: 1.5)
        try await rig.idle()
        #expect(rig.inserter.texts.get.isEmpty)
        #expect(try await rig.saved().map(\.status) == [.cancelled])
    }

    @Test func silentMicStopsAfterFiveSeconds() async throws {
        let rig = try DCRig()
        rig.controller.send(.startMic, at: 1)
        rig.controller.send(.confirmDictation, at: 1.3)
        try await Task.sleep(nanoseconds: 20_000_000)
        rig.mic.push(130, level: 0)            // 5.2 s of zeros
        try await rig.idle()
        #expect(rig.events.get.contains(.micSilent))
        rig.controller.send(.finish, at: 7)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(rig.inserter.texts.get.isEmpty)
        #expect(try await rig.saved().isEmpty)
    }
}
