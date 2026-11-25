import Accelerate
import Foundation

/// Log-mel front end of GigaAM v3: 16 kHz, 320-sample periodic Hann window, hop 160, no padding,
/// power spectrum, 64 HTK mel bands up to 8 kHz, `log(clamp(x, 1e-9, 1e9))`.
/// (Same maths as the reference preprocessor of the open `onnx-asr` package; written from scratch.)
struct GigaAMFeatures: Sendable {
    static let nFFT = 320
    static let hop = 160
    static let bins = nFFT / 2 + 1      // 161
    static let mels = 64

    let window: [Float]
    /// `[bin * 64 + mel]`, row-major 161 x 64.
    let melFilters: [Float]

    init() {
        let n = Self.nFFT
        window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        melFilters = Self.makeMelFilters()
    }

    func frameCount(sampleCount: Int) -> Int {
        sampleCount < Self.nFFT ? 0 : (sampleCount - Self.nFFT) / Self.hop + 1
    }

    private static func makeMelFilters() -> [Float] {
        func hzToMel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func melToHz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let sampleRate = 16_000.0
        let allFreqs = (0..<bins).map { Double($0) * (sampleRate / 2) / Double(bins - 1) }
        let mMax = hzToMel(sampleRate / 2)
        let fPts = (0..<(mels + 2)).map { melToHz(mMax * Double($0) / Double(mels + 1)) }
        var out = [Float](repeating: 0, count: bins * mels)
        for m in 0..<mels {
            let lo = fPts[m], mid = fPts[m + 1], hi = fPts[m + 2]
            for k in 0..<bins {
                let down = (allFreqs[k] - lo) / (mid - lo)
                let up = (hi - allFreqs[k]) / (hi - mid)
                out[k * mels + m] = Float(max(0, min(down, up)))
            }
        }
        return out
    }

    /// Returns `64 x T` features, row-major (`mel * T + frame`), ready for the encoder's
    /// `[1, 64, T]` input. Empty when the audio is shorter than one window.
    func logMel(samples: [Float]) -> [Float] {
        let T = frameCount(sampleCount: samples.count)
        guard T > 0 else { return [] }
        let n = Self.nFFT, bins = Self.bins, mels = Self.mels, half = n / 2
        guard let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD) else { return [] }
        defer { vDSP_DFT_DestroySetup(setup) }

        var power = [Float](repeating: 0, count: T * bins)
        var framed = [Float](repeating: 0, count: n)
        var inRe = [Float](repeating: 0, count: half), inIm = [Float](repeating: 0, count: half)
        var outRe = [Float](repeating: 0, count: half), outIm = [Float](repeating: 0, count: half)

        samples.withUnsafeBufferPointer { src in
            for t in 0..<T {
                vDSP_vmul(src.baseAddress! + t * Self.hop, 1, window, 1, &framed, 1, vDSP_Length(n))
                // Real input packed as even → real, odd → imaginary.
                for i in 0..<half { inRe[i] = framed[2 * i]; inIm[i] = framed[2 * i + 1] }
                vDSP_DFT_Execute(setup, inRe, inIm, &outRe, &outIm)
                // vDSP's real DFT is 2x the textbook one; DC in re[0], Nyquist in im[0].
                let base = t * bins
                power[base] = (outRe[0] * 0.5) * (outRe[0] * 0.5)
                power[base + half] = (outIm[0] * 0.5) * (outIm[0] * 0.5)
                for k in 1..<half {
                    let re = outRe[k] * 0.5, im = outIm[k] * 0.5
                    power[base + k] = re * re + im * im
                }
            }
        }

        // (T x 161) * (161 x 64) → T x 64
        var mel = [Float](repeating: 0, count: T * mels)
        vDSP_mmul(power, 1, melFilters, 1, &mel, 1, vDSP_Length(T), vDSP_Length(mels), vDSP_Length(bins))
        var lo: Float = 1e-9, hi: Float = 1e9
        vDSP_vclip(mel, 1, &lo, &hi, &mel, 1, vDSP_Length(mel.count))
        var count = Int32(mel.count)
        vvlogf(&mel, mel, &count)

        var out = [Float](repeating: 0, count: mels * T)
        vDSP_mtrans(mel, 1, &out, 1, vDSP_Length(mels), vDSP_Length(T))
        return out
    }
}
