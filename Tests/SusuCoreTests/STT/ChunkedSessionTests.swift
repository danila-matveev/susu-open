import Foundation
import Testing
@testable import SusuCore

/// Records uploads; text of a piece is "p<sample count>" so order and size are visible.
final class FakeUploader: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [Int] = []
    var delaysByCall: [Int: Double] = [:]
    var uploadSizes: [Int] { lock.withLock { sizes } }
    func upload(_ samples: [Int16]) async throws -> UploadedText {
        let call = lock.withLock { sizes.append(samples.count); return sizes.count - 1 }
        if let d = delaysByCall[call] { try await Task.sleep(nanoseconds: UInt64(d * 1e9)) }
        return UploadedText(text: "p\(samples.count)", language: "ru")
    }
}

private func chunk(_ i: Int) -> AudioChunk {
    AudioChunk(samples: [Int16](repeating: 1, count: 640), startMs: i * 40)
}

@Suite struct ChunkedSessionTests {
    func session(_ up: FakeUploader, pauses: Set<Int> = [], split: Double = 20) -> (ChunkedSTTSession, Counter) {
        let counter = Counter()
        let s = ChunkedSTTSession(provider: .groq, model: "m", splitAfterSeconds: split,
                                  pauseEnded: { _ in counter.next(in: pauses) },
                                  upload: { s, _ in try await up.upload(s) })
        return (s, counter)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var i = 0
        /// Called once per chunk, in order: true if this chunk index is a "pause just ended" one.
        func next(in set: Set<Int>) -> Bool { lock.withLock { defer { i += 1 }; return set.contains(i) } }
    }

    @Test func shortPhraseIsOneUploadAtFinish() async throws {
        let up = FakeUploader()
        let (s, _) = session(up, pauses: [10])   // a pause, but far below 20 s
        for i in 0..<50 { s.append(chunk(i)) }   // 2 s
        #expect(up.uploadSizes.isEmpty)
        let t = try await s.finish()
        #expect(up.uploadSizes == [50 * 640])
        #expect(t.text == "p32000" && t.audioSeconds == 2.0 && t.language == "ru")
    }

    @Test func longSpeechSplitsAtPauseAfterTwentySeconds() async throws {
        let up = FakeUploader()
        // 30 s = 750 chunks; pauses end at chunk 100 (5 s: too early), 600 (24 s: split), 700 (not enough pending)
        let (s, _) = session(up, pauses: [100, 600, 700])
        for i in 0..<750 { s.append(chunk(i)) }
        // the piece goes out during speech, before finish
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(up.uploadSizes == [600 * 640])
        let t = try await s.finish()
        #expect(up.uploadSizes == [600 * 640, 150 * 640])   // finish sent only the tail
        #expect(t.text == "p384000 p96000")
        #expect(t.audioSeconds == 30)
    }

    @Test func textsJoinInSpeechOrderEvenIfAnEarlierPieceIsSlower() async throws {
        let up = FakeUploader()
        up.delaysByCall = [0: 0.2]
        let (s, _) = session(up, pauses: [550, 1100])
        for i in 0..<1200 { s.append(chunk(i)) }   // 48 s: pieces at 550 and 1100
        let t = try await s.finish()
        #expect(t.text == "p\(550 * 640) p\(550 * 640) p\(100 * 640)")
    }

    @Test func noPauseCallbackMeansNoEarlySend() async throws {
        let up = FakeUploader()
        let s = ChunkedSTTSession(provider: .groq, model: "m", upload: { s, _ in try await up.upload(s) })
        for i in 0..<800 { s.append(chunk(i)) }
        #expect(up.uploadSizes.isEmpty)
        _ = try await s.finish()
        #expect(up.uploadSizes == [800 * 640])
    }

    @Test func failedPieceFailsFinish() async throws {
        let s = ChunkedSTTSession(provider: .groq, model: "m", splitAfterSeconds: 1,
                                  pauseEnded: { $0.startMs == 2000 }, upload: { _, _ in throw STTError.rateLimited })
        for i in 0..<100 { s.append(chunk(i)) }
        await #expect(throws: STTError.rateLimited) { _ = try await s.finish() }
    }

    @Test func cancelThenFinishThrowsCancelled() async {
        let up = FakeUploader()
        let (s, _) = session(up)
        s.append(chunk(0)); s.cancel()
        await #expect(throws: STTError.cancelled) { _ = try await s.finish() }
        #expect(up.uploadSizes.isEmpty)
    }

    @Test func emptySessionGivesEmptyTextWithoutUpload() async throws {
        let up = FakeUploader()
        let (s, _) = session(up)
        let t = try await s.finish()
        #expect(t.text.isEmpty && up.uploadSizes.isEmpty)
    }

    @Test func nextPieceGetsPreviousTextAsContext() async throws {
        final class Seen: @unchecked Sendable { let lock = NSLock(); var prevs: [String?] = [] }
        let seen = Seen()
        let counter = Counter()
        let s = ChunkedSTTSession(provider: .groq, model: "m", splitAfterSeconds: 1,
                                  pauseEnded: { _ in counter.next(in: [30, 60]) },
                                  upload: { samples, prev in
                                      seen.lock.withLock { seen.prevs.append(prev) }
                                      return UploadedText(text: "p\(samples.count)")
                                  })
        for i in 0..<60 { s.append(chunk(i)) }
        try await Task.sleep(nanoseconds: 100_000_000)   // let the first piece come back
        for i in 60..<70 { s.append(chunk(i)) }
        _ = try await s.finish()
        let prevs = seen.lock.withLock { seen.prevs }
        #expect(prevs.count == 3)
        #expect(prevs[0] == nil)
        #expect(prevs.contains("p19200"))
    }

    @Test func promptKeepsContextWithinBudget() {
        let hint = (0..<200).map { "Term\($0)" }.joined(separator: ", ")
        let p = OpenAICompatibleTranscription.prompt(hint, previousText: "и потом мы обсудили Sprout и план")
        #expect(p.hasSuffix("и потом мы обсудили Sprout и план"))
        #expect(STTHintBuilder.estimatedTokens(p) <= 224)
        #expect(OpenAICompatibleTranscription.prompt("A, B", previousText: nil) == "A, B")
    }
}

