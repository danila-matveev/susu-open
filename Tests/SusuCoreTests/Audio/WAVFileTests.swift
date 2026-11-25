import AVFoundation
import Foundation
import Testing
@testable import SusuCore

@Suite struct WAVFileTests {
    private func tmp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("susu-test-\(UUID().uuidString)-\(name)")
    }

    @Test func headerIsValidRIFF() throws {
        let url = tmp("a.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let sig = TestSignals.tone(ms: 1000)
        try WAVFile.write(samples: sig, to: url)
        let d = try Data(contentsOf: url)
        #expect(d.count == 44 + sig.count * 2)
        #expect(String(decoding: d[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: d[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: d[12..<16], as: UTF8.self) == "fmt ")
        #expect(String(decoding: d[36..<40], as: UTF8.self) == "data")
        func u32(_ o: Int) -> UInt32 { d[o..<o + 4].withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } }
        func u16(_ o: Int) -> UInt16 { d[o..<o + 2].withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) } }
        #expect(u32(4) == UInt32(d.count - 8))
        #expect(u16(20) == 1 && u16(22) == 1)
        #expect(u32(24) == 16_000 && u32(28) == 32_000)
        #expect(u16(32) == 2 && u16(34) == 16)
        #expect(u32(40) == UInt32(sig.count * 2))
    }

    @Test func fileLengthMatchesSignal() throws {
        let url = tmp("b.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let sig = TestSignals.tone(ms: 2345)
        try WAVFile.write(samples: sig, to: url)
        let file = try AVAudioFile(forReading: url)
        let ms = Double(file.length) / file.fileFormat.sampleRate * 1000
        #expect(abs(ms - 2345) <= 40)
        #expect(file.fileFormat.channelCount == 1)
    }

    @Test func streamingWriterAppendsInPieces() throws {
        let url = tmp("c.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let sig = TestSignals.tone(ms: 1000)
        let w = try WAVWriter(url: url)
        for c in TestSignals.chunks(sig) { try w.append(c.samples) }
        try w.finalize()
        #expect(w.sampleCount == sig.count)
        #expect(try WAVFile.readSamples(url) == sig)
    }

    @Test func roundTrip() throws {
        let url = tmp("d.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let sig = TestSignals.tone(ms: 700) + TestSignals.silence(ms: 100)
        try WAVFile.write(samples: sig, to: url)
        #expect(try WAVFile.readSamples(url) == sig)
    }

    @Test func resamplesStereo44kTo16kMono() throws {
        let url = tmp("e.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 44_100.0
        let frames = AVAudioFrameCount(2 * rate)   // 2 s
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 2, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) {
            let v = Int16(8000 * sin(2 * .pi * 440 * Double(i) / rate))
            buf.int16ChannelData![0][i] = v
            buf.int16ChannelData![1][i] = v
        }
        do {
            let out = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatInt16, interleaved: false)
            try out.write(from: buf)
        }
        let samples = try WAVFile.readSamples(url)
        #expect(abs(samples.count - 32_000) <= 640)
        let rms = PauseDetector.rms(Array(samples[2000..<30_000]))
        // sine of amplitude 8000 has RMS ~5657; downmix of identical channels keeps level
        #expect(abs(rms - 5657) < 600)
    }
}
