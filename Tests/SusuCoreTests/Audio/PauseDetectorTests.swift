import Testing
@testable import SusuCore

@Suite struct PauseDetectorTests {
    /// Runs the detector over chunks; returns (pauseStartMs, detectedAtMs) for each pause.
    private func pauses(_ signal: [Int16]) -> [(start: Int, at: Int)] {
        var d = PauseDetector()
        var out: [(Int, Int)] = []
        for c in TestSignals.chunks(signal) where d.feed(c) {
            out.append((d.pauseStartMs!, c.startMs + c.durationMs))
        }
        return out.map { (start: $0.0, at: $0.1) }
    }

    @Test func findsPauseWithinOneChunk() {
        // 1.0 s tone, 0.5 s silence, 1.0 s tone: the silence begins at exactly 1000 ms.
        let sig = TestSignals.tone(ms: 1000) + TestSignals.silence(ms: 500) + TestSignals.tone(ms: 1000)
        let p = pauses(sig)
        #expect(p.count == 1)
        #expect(abs(p[0].start - 1000) <= 40)
        // reported once 300 ms of silence has gone by
        #expect(abs(p[0].at - 1300) <= 40)
    }

    @Test func pauseNotAlignedToChunkGrid() {
        let sig = TestSignals.tone(ms: 1015) + TestSignals.silence(ms: 600) + TestSignals.tone(ms: 500)
        let p = pauses(sig)
        #expect(p.count == 1)
        #expect(abs(p[0].start - 1015) <= 40)
    }

    @Test func shortGapIsNotAPause() {
        let sig = TestSignals.tone(ms: 800) + TestSignals.silence(ms: 240) + TestSignals.tone(ms: 800)
        #expect(pauses(sig).isEmpty)
    }

    @Test func leadingSilenceIsNotAPause() {
        let sig = TestSignals.silence(ms: 1000) + TestSignals.tone(ms: 500)
        #expect(pauses(sig).isEmpty)
    }

    @Test func longSilenceReportsOnlyOnce() {
        let sig = TestSignals.tone(ms: 500) + TestSignals.silence(ms: 3000)
        #expect(pauses(sig).count == 1)
    }

    @Test func twoPauses() {
        let sig = TestSignals.tone(ms: 600) + TestSignals.silence(ms: 400)
            + TestSignals.tone(ms: 600) + TestSignals.silence(ms: 400) + TestSignals.tone(ms: 200)
        let p = pauses(sig)
        #expect(p.count == 2)
        #expect(abs(p[0].start - 600) <= 40)
        #expect(abs(p[1].start - 1600) <= 40)
    }

    @Test func lowNoiseCountsAsSilence() {
        let sig = TestSignals.tone(ms: 800) + TestSignals.noise(ms: 600) + TestSignals.tone(ms: 400)
        let p = pauses(sig)
        #expect(p.count == 1)
        #expect(abs(p[0].start - 800) <= 40)
    }

    @Test func trailingTrimKeepsShortTail() {
        let speech = TestSignals.tone(ms: 1000)
        let sig = speech + TestSignals.silence(ms: 2000)
        let trimmed = PauseDetector.trailingSilenceTrim(sig, keepTailMs: 120)
        let ms = trimmed.count / 16
        #expect(ms >= 1000 + 100 && ms <= 1000 + 120 + 40)
        #expect(Array(trimmed[..<speech.count]) == speech)
    }

    @Test func trailingTrimWithNoiseTail() {
        let sig = TestSignals.tone(ms: 1000) + TestSignals.noise(ms: 1500)
        let ms = PauseDetector.trailingSilenceTrim(sig).count / 16
        #expect(ms <= 1000 + 120 + 40)
    }

    @Test func trimLeavesRecordingWithoutTrailingSilenceAlone() {
        let sig = TestSignals.silence(ms: 200) + TestSignals.tone(ms: 1000)
        #expect(PauseDetector.trailingSilenceTrim(sig) == sig)
    }

    @Test func trimOfPureSilenceIsEmpty() {
        #expect(PauseDetector.trailingSilenceTrim(TestSignals.silence(ms: 2000)).isEmpty)
    }

    @Test func silentRecordingCheck() {
        #expect(PauseDetector.isSilentRecording(TestSignals.silence(ms: 5000)))
        #expect(!PauseDetector.isSilentRecording(TestSignals.silence(ms: 3000)))   // not enough audio yet
        #expect(!PauseDetector.isSilentRecording(TestSignals.silence(ms: 4000) + TestSignals.tone(ms: 1500)))
        #expect(!PauseDetector.isSilentRecording(TestSignals.noise(ms: 5000)))
        #expect(PauseDetector.isSilentRecording(TestSignals.silence(ms: 5000) + TestSignals.tone(ms: 500)))
    }
}
