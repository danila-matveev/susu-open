// Wave math from DESIGN.md section 5: the level is sampled ~7 times a second, the shown value eases toward
// it by 25% per 60 fps frame; bar height = max(breath, level x weight); in silence bars breathe 30-45% over
// 1.6 s, each bar phase-shifted 80 ms per step from the centre.
import Foundation

@MainActor
final class WaveSampler {
    static let weights: [Double] = [0.5, 0.6, 0.72, 0.86, 1, 1, 0.86, 0.72, 0.6, 0.5]
    /// Phase offset in 80 ms steps (k in the prototype CSS).
    static let phase: [Double] = [4.5, 3.5, 2.5, 1.5, 0.5, 0.5, 1.5, 2.5, 3.5, 4.5]
    static let frame: Double = 1.0 / 60

    private var target: Double = 0
    private var shown: Double = 0
    private var lastAdvance: TimeInterval?
    private var lastInput: TimeInterval = 0

    func setTarget(_ level: Float, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        target = min(1, max(0, Double(level)))
        lastInput = now
    }

    /// Advances the smoothing by the real time passed (so 120 Hz screens look the same) and returns the shown level.
    func advance(now: TimeInterval) -> Double {
        // Without fresh input for 0.6 s the mic is considered quiet.
        let t = now - lastInput > 0.6 ? 0 : target
        let dt = lastAdvance.map { min(0.25, max(0, now - $0)) } ?? Self.frame
        lastAdvance = now
        let frames = dt / Self.frame
        shown += (t - shown) * (1 - pow(0.75, frames))
        return shown
    }

    func reset() { shown = 0; target = 0; lastAdvance = nil }

    /// Heights as fractions of the full wave height, one per bar.
    static func scales(level: Double, time: Double, breathing: Bool) -> [Double] {
        (0..<10).map { i in
            let breath: Double
            if breathing {
                let p = (time + phase[i] * 0.08) / 1.6
                breath = 0.3 + 0.15 * (0.5 - 0.5 * cos(2 * .pi * p))
            } else {
                breath = 0.3
            }
            return max(breath, level * weights[i])
        }
    }
}
