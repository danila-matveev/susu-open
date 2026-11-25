import Foundation

/// Energy-based pause detection against an adaptive noise floor (spec 3.2).
/// Feed 40 ms chunks in order; `feed` returns true on the chunk where a pause of
/// at least `minPauseMs` of silence (after some speech) has just completed.
public struct PauseDetector: Sendable {
    public let minPauseMs: Int
    /// Start of the silence run that produced the last reported pause, ms from recording start.
    public private(set) var pauseStartMs: Int?
    public private(set) var noiseFloor: Double = 50
    private var silenceMs = 0
    private var silenceStartMs = 0
    private var heardSpeech = false
    private var reported = false

    public init(minPauseMs: Int = 300) { self.minPauseMs = minPauseMs }

    /// Silence below this RMS (Int16 units) is never speech, whatever the floor says (~ -44 dBFS).
    static let absoluteMinThreshold = 150.0

    public var threshold: Double { max(noiseFloor * 3, Self.absoluteMinThreshold) }

    public mutating func feed(_ chunk: AudioChunk) -> Bool {
        guard !chunk.samples.isEmpty else { return false }
        let rms = Self.rms(chunk.samples)
        let isSpeech = rms >= threshold
        if isSpeech {
            noiseFloor += (rms - noiseFloor) * 0.0005   // creeps up so steady loud noise is learned eventually
            heardSpeech = true
            silenceMs = 0
            reported = false
            return false
        }
        // Quiet chunk: floor drops at once, rises slowly.
        noiseFloor = rms < noiseFloor ? max(rms, 1) : noiseFloor + (rms - noiseFloor) * 0.02
        if silenceMs == 0 { silenceStartMs = chunk.startMs }
        silenceMs += chunk.durationMs
        if heardSpeech, !reported, silenceMs >= minPauseMs {
            reported = true
            pauseStartMs = silenceStartMs
            return true
        }
        return false
    }

    // MARK: - Offline helpers

    public static func rms(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for s in samples { let v = Double(s); sum += v * v }
        return (sum / Double(samples.count)).squareRoot()
    }
    public static func rms(_ samples: [Int16]) -> Double { rms(samples[...]) }

    /// Cuts silence at the end of a recording, keeping `keepTailMs` after the last speech frame.
    /// The threshold is derived from the signal itself (low-percentile frame energy as floor).
    /// Returns [] when the recording holds no speech at all.
    public static func trailingSilenceTrim(_ samples: [Int16], keepTailMs: Int = 120) -> [Int16] {
        let frame = AudioChunk.samplesPer40ms
        guard samples.count >= frame else { return rms(samples) >= absoluteMinThreshold ? samples : [] }
        let frames = (samples.count + frame - 1) / frame
        let energies: [Double] = (0..<frames).map { i in
            rms(samples[(i * frame)..<min(samples.count, (i + 1) * frame)])
        }
        let sorted = energies.sorted()
        let floor = max(sorted[sorted.count / 10], 1)
        let peak = sorted[sorted.count - 1]
        guard peak >= absoluteMinThreshold else { return [] }
        let threshold = min(max(floor * 3, absoluteMinThreshold), peak * 0.2)
        guard let last = energies.lastIndex(where: { $0 >= threshold }) else { return [] }
        let end = min(samples.count, (last + 1) * frame + keepTailMs * AudioChunk.sampleRate / 1000)
        return Array(samples[..<end])
    }

    /// True when the first `firstSeconds` of the recording are digital silence (mic gave no signal).
    /// False while there is less audio than that, so callers can poll as chunks arrive.
    public static func isSilentRecording(_ samples: [Int16], firstSeconds: Double = 5) -> Bool {
        let n = Int(firstSeconds * Double(AudioChunk.sampleRate))
        guard samples.count >= n else { return false }
        for s in samples[..<n] where abs(Int(s)) > 1 { return false }
        return true
    }
}
