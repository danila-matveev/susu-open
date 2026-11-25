import Foundation

/// Cuts a stream of 16 kHz samples into 40 ms `AudioChunk`s.
struct ChunkSlicer {
    private var pending: [Int16] = []
    private var emitted = 0   // samples already turned into chunks

    mutating func append(_ samples: [Int16]) -> [AudioChunk] {
        pending.append(contentsOf: samples)
        var out: [AudioChunk] = []
        let n = AudioChunk.samplesPer40ms
        var offset = 0
        while pending.count - offset >= n {
            out.append(AudioChunk(samples: Array(pending[offset..<offset + n]),
                                  startMs: emitted * 1000 / AudioChunk.sampleRate))
            emitted += n
            offset += n
        }
        if offset > 0 { pending.removeFirst(offset) }
        return out
    }

    /// The last, possibly shorter chunk.
    mutating func flush() -> AudioChunk? {
        guard !pending.isEmpty else { return nil }
        let c = AudioChunk(samples: pending, startMs: emitted * 1000 / AudioChunk.sampleRate)
        emitted += pending.count
        pending = []
        return c
    }
}

/// Turns samples into a 0…1 loudness value about every 140 ms (~7 per second).
struct LevelMeter {
    static let windowSamples = AudioChunk.sampleRate * 140 / 1000
    private var sumSquares = 0.0
    private var count = 0

    /// Speech RMS sits around -35…-15 dBFS; -50 dBFS maps to 0 and -14 dBFS to 1.
    static func normalized(rms: Double) -> Float {
        let db = 20 * log10(max(rms / 32768, 1e-6))
        return Float(min(max((db + 50) / 36, 0), 1))
    }

    mutating func feed(_ samples: [Int16]) -> [Float] {
        var out: [Float] = []
        for s in samples {
            let v = Double(s)
            sumSquares += v * v
            count += 1
            if count == Self.windowSamples {
                out.append(Self.normalized(rms: (sumSquares / Double(count)).squareRoot()))
                sumSquares = 0
                count = 0
            }
        }
        return out
    }
}
