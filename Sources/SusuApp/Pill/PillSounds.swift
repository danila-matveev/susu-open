// Own short tones, generated in code (no sound files): start rises ~80 ms, stop falls ~80 ms, error is a low double tap.
import AVFoundation

@MainActor
final class PillSounds {
    enum Kind: CaseIterable { case start, stop, error }

    private var players: [Kind: AVAudioPlayer] = [:]

    func play(_ kind: Kind) {
        let player: AVAudioPlayer
        if let p = players[kind] { player = p } else {
            guard let p = try? AVAudioPlayer(data: Self.wav(for: kind)) else { return }
            p.volume = 0.5
            p.prepareToPlay()
            players[kind] = p
            player = p
        }
        player.currentTime = 0
        player.play()
    }

    // MARK: synthesis

    static let sampleRate = 44_100.0

    /// A sine sweep from `f0` to `f1` Hz over `ms`, with a short attack/release so it does not click.
    static func sweep(_ f0: Double, _ f1: Double, ms: Double, gain: Double = 0.6) -> [Float] {
        let n = Int(sampleRate * ms / 1000)
        var phase = 0.0
        return (0..<n).map { i in
            let p = Double(i) / Double(n)
            phase += 2 * .pi * (f0 + (f1 - f0) * p) / sampleRate
            let env = min(1, p / 0.12) * min(1, (1 - p) / 0.35)
            return Float(sin(phase) * env * gain)
        }
    }

    static func samples(for kind: Kind) -> [Float] {
        switch kind {
        case .start: sweep(520, 780, ms: 80)
        case .stop: sweep(780, 520, ms: 80)
        case .error:
            sweep(210, 190, ms: 55) + [Float](repeating: 0, count: Int(sampleRate * 0.07)) + sweep(210, 190, ms: 55)
        }
    }

    static func wav(for kind: Kind) -> Data {
        let pcm = samples(for: kind).map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(pcm.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in pcm { u16(UInt16(bitPattern: s)) }
        return d
    }
}
