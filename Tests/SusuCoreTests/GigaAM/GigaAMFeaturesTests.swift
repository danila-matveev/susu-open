import Foundation
import Testing
@testable import SusuCore

@Suite struct GigaAMFeaturesTests {
    @Test func frameCountMatchesReference() {
        // Reference: (len - 320) / 160 + 1, no padding.
        let f = GigaAMFeatures()
        #expect(f.frameCount(sampleCount: 16_000) == 99)
        #expect(f.frameCount(sampleCount: 320) == 1)
        #expect(f.frameCount(sampleCount: 319) == 0)
    }

    @Test func melFilterbankShapeAndRange() {
        let f = GigaAMFeatures()
        #expect(f.melFilters.count == 161 * 64)
        #expect(f.melFilters.allSatisfy { $0 >= 0 && $0 <= 1.0001 })
        // Every mel band has some weight.
        for m in 0..<64 {
            var s: Float = 0
            for k in 0..<161 { s += f.melFilters[k * 64 + m] }
            #expect(s > 0)
        }
    }

    @Test func windowIsPeriodicHann() {
        let f = GigaAMFeatures()
        #expect(f.window.count == 320)
        #expect(f.window[0] == 0)
        #expect(abs(f.window[160] - 1) < 1e-6)
        #expect(abs(f.window[80] - 0.5) < 1e-6)
    }

    /// Straight-line (slow) implementation of the same maths, to check the vDSP path.
    @Test func matchesNaiveDFT() {
        let f = GigaAMFeatures()
        var samples = [Float](repeating: 0, count: 1600)
        for i in 0..<samples.count {
            let t = Float(i) / 16_000
            samples[i] = 0.4 * sinf(2 * .pi * 440 * t) + 0.2 * sinf(2 * .pi * 3100 * t + 1) + 0.01 * Float((i * 7919) % 13 - 6)
        }
        let got = f.logMel(samples: samples)           // [64][T] flattened as m * T + t
        let T = f.frameCount(sampleCount: samples.count)
        #expect(got.count == 64 * T)
        for t in [0, 3, T - 1] {
            var spec = [Double](repeating: 0, count: 161)
            for k in 0..<161 {
                var re = 0.0, im = 0.0
                for n in 0..<320 {
                    let x = Double(samples[t * 160 + n] * f.window[n])
                    let a = -2 * Double.pi * Double(k * n) / 320
                    re += x * cos(a); im += x * sin(a)
                }
                spec[k] = re * re + im * im
            }
            for m in [0, 10, 33, 63] {
                var e = 0.0
                for k in 0..<161 { e += spec[k] * Double(f.melFilters[k * 64 + m]) }
                let want = log(min(max(e, 1e-9), 1e9))
                #expect(abs(Double(got[m * T + t]) - want) < 2e-3, "m=\(m) t=\(t) got=\(got[m * T + t]) want=\(want)")
            }
        }
    }

    @Test func silenceClampsToLogFloor() {
        let f = GigaAMFeatures()
        let out = f.logMel(samples: [Float](repeating: 0, count: 640))
        #expect(out.allSatisfy { abs($0 - Float(log(1e-9))) < 1e-4 })
    }
}

@Suite struct GigaAMTextTests {
    @Test func joinsTokensLikeReference() {
        // "▁" marks a word start. Space before punctuation is dropped, leading space is dropped.
        #expect(GigaAMDecoder.detokenize(["▁при", "вет", ",", "▁мир", "."]) == "привет, мир.")
        #expect(GigaAMDecoder.detokenize(["▁а", "▁", ",", "▁б"]) == "а, б")
        #expect(GigaAMDecoder.detokenize(["▁он", "▁—", "▁тут"]) == "он — тут")
        #expect(GigaAMDecoder.detokenize(["▁«", "да", "».", "▁Но"]) == "«да». Но")
        #expect(GigaAMDecoder.detokenize([]) == "")
    }
}
