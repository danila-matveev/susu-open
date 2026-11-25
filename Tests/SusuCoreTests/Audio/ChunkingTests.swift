import Testing
@testable import SusuCore

@Suite struct ChunkingTests {
    @Test func slicerMakes40msChunksWithOffsets() {
        var s = ChunkSlicer()
        var all: [AudioChunk] = []
        // feed in awkward piece sizes
        let sig = TestSignals.tone(ms: 1000)
        var i = 0
        for size in [1, 333, 1000, 17, 5000, 9649] {
            all += s.append(Array(sig[i..<min(sig.count, i + size)]))
            i += size
        }
        #expect(i >= sig.count)
        #expect(all.count == 25)
        #expect(all.allSatisfy { $0.samples.count == 640 })
        #expect(all.enumerated().allSatisfy { $0.element.startMs == $0.offset * 40 })
        #expect(all.flatMap(\.samples) == sig)
        #expect(s.flush() == nil)
    }

    @Test func slicerFlushesShortTail() {
        var s = ChunkSlicer()
        _ = s.append(TestSignals.tone(ms: 100))
        let tail = s.flush()
        #expect(tail?.samples.count == 320)
        #expect(tail?.startMs == 80)
    }

    @Test func levelRateAboutSevenPerSecond() {
        var m = LevelMeter()
        let n = m.feed(TestSignals.tone(ms: 2000)).count
        #expect(n >= 13 && n <= 15)
    }

    @Test func levelIsNormalized() {
        var m = LevelMeter()
        #expect(m.feed(TestSignals.silence(ms: 300)).allSatisfy { $0 == 0 })
        let speechLike = m.feed(TestSignals.tone(ms: 300, amp: 3000))   // ~ -22 dBFS RMS
        #expect(speechLike.allSatisfy { $0 > 0.5 && $0 < 1 })
        let loud = m.feed(TestSignals.tone(ms: 300, amp: 30_000))
        #expect(loud.allSatisfy { $0 == 1 })
    }
}

#if os(macOS)
@Suite struct MicDevicePickTests {
    let builtIn = MicInputDevice(uid: "BuiltInMic", name: "MacBook Pro Microphone", isBuiltIn: true)
    let bh = MicInputDevice(uid: "BlackHole2ch_UID", name: "BlackHole 2ch")
    let usb = MicInputDevice(uid: "usb-1", name: "Yeti")

    @Test func priorityOrderWins() {
        let d = MicDevices.pick(priority: ["missing", "usb-1", "BlackHole2ch_UID"], available: [builtIn, bh, usb], defaultUID: "BuiltInMic", lidClosed: false)
        #expect(d == usb)
    }
    @Test func matchesByNameForBlackHole() {
        let d = MicDevices.pick(priority: ["BlackHole 2ch"], available: [builtIn, bh], defaultUID: "BuiltInMic", lidClosed: false)
        #expect(d == bh)
    }
    @Test func fallsBackToDefault() {
        let d = MicDevices.pick(priority: [], available: [builtIn, usb], defaultUID: "usb-1", lidClosed: false)
        #expect(d == usb)
    }
    @Test func skipsBuiltInWhenLidClosed() {
        let d = MicDevices.pick(priority: [], available: [builtIn, usb], defaultUID: "BuiltInMic", lidClosed: true)
        #expect(d == usb)
        #expect(MicDevices.pick(priority: [], available: [builtIn], defaultUID: "BuiltInMic", lidClosed: true) == nil)
    }
}
#endif
