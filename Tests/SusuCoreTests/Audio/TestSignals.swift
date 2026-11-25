import Foundation
@testable import SusuCore

enum TestSignals {
    static func tone(ms: Int, freq: Double = 440, amp: Double = 8000, rate: Int = 16_000) -> [Int16] {
        (0..<(ms * rate / 1000)).map { Int16(amp * sin(2 * .pi * freq * Double($0) / Double(rate))) }
    }
    static func silence(ms: Int, rate: Int = 16_000) -> [Int16] {
        [Int16](repeating: 0, count: ms * rate / 1000)
    }
    /// Low-level deterministic noise, roughly -60 dBFS.
    static func noise(ms: Int, amp: Int = 30) -> [Int16] {
        var x: UInt32 = 12345
        return (0..<(ms * 16)).map { _ in
            x = x &* 1664525 &+ 1013904223
            return Int16(Int(x >> 16) % (2 * amp + 1) - amp)
        }
    }
    static func chunks(_ samples: [Int16]) -> [AudioChunk] {
        var s = ChunkSlicer()
        var out = s.append(samples)
        if let t = s.flush() { out.append(t) }
        return out
    }
}
