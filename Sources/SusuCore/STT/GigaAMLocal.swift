import Foundation
import OnnxRuntimeBindings

// GigaAM v3 e2e RNN-T (int8) through onnxruntime on the CPU (spec 2.1: the CoreML provider crashes
// on this model). Sessions are loaded once, lazily, and stay warm. The algorithm follows the open
// `onnx-asr` reference: log-mel → encoder → greedy transducer decode with decoder + joint.

enum GigaAMDecoder {
    /// Joins SentencePiece-style tokens ("▁" = word start) into text. Spaces before closing
    /// punctuation and at the edges are dropped, like the reference.
    static func detokenize(_ tokens: [String]) -> String {
        let raw = tokens.joined().replacingOccurrences(of: "\u{2581}", with: " ")
        let chars = Array(raw)
        let noSpaceBefore: Set<Character> = [".", ",", "?", "!", ":", ";", ")", "»", "%", "\""]
        var out = ""
        for (i, c) in chars.enumerated() {
            if c == " " {
                if out.isEmpty { continue }
                guard i + 1 < chars.count else { continue }
                let next = chars[i + 1]
                if next == " " || noSpaceBefore.contains(next) { continue }
            }
            out.append(c)
        }
        return out
    }
}

public enum GigaAMModelFiles {
    public static let directoryName = "gigaam-v3"
    public static let encoder = "v3_e2e_rnnt_encoder.int8.onnx"
    public static let decoder = "v3_e2e_rnnt_decoder.int8.onnx"
    public static let joint = "v3_e2e_rnnt_joint.int8.onnx"
    public static let vocab = "v3_e2e_rnnt_vocab.txt"
    public static let config = "config.json"
    public static let all = [encoder, decoder, joint, vocab, config]

    public static func isPresent(in dir: URL) -> Bool {
        all.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }
}

/// The three ONNX sessions and the decode loop. Thread-safe: each call keeps its own decode state.
public final class GigaAMEngine: @unchecked Sendable {
    private static let hiddenSize = 320
    private static let maxTokensPerStep = 3
    private static let queue = DispatchQueue(label: "susu.gigaam", qos: .userInitiated, attributes: .concurrent)

    private struct Loaded {
        let env: ORTEnv
        let encoder: ORTSession, decoder: ORTSession, joint: ORTSession
        let vocab: [String]
        let blank: Int
    }

    private let modelDir: URL
    private let features = GigaAMFeatures()
    private let lock = NSLock()
    private var loaded: Loaded?

    public init(modelDir: URL) { self.modelDir = modelDir }

    public var isModelPresent: Bool { GigaAMModelFiles.isPresent(in: modelDir) }

    /// Loads the sessions now (idempotent). Call ahead of the first dictation to keep latency low.
    public func warmUp() throws { _ = try load() }

    /// Recognizes 16 kHz mono audio on a background queue.
    public func transcribe(_ pcm: [Int16]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            Self.queue.async {
                cont.resume(with: Result { try self.transcribeSync(pcm) })
            }
        }
    }

    func transcribeSync(_ pcm: [Int16]) throws -> String {
        let model = try load()
        var samples = [Float](repeating: 0, count: pcm.count)
        for i in 0..<pcm.count { samples[i] = Float(pcm[i]) / 32768 }
        let feats = features.logMel(samples: samples)
        let T = features.frameCount(sampleCount: samples.count)
        guard T > 0 else { return "" }
        do {
            let (enc, encLen, dim) = try runEncoder(model, feats: feats, frames: T)
            let tokens = try greedyDecode(model, enc: enc, length: encLen, dim: dim, frames: enc.count / dim)
            return GigaAMDecoder.detokenize(tokens.map { model.vocab[$0] })
        } catch let e as STTError {
            throw e
        } catch {
            throw STTError.badResponse("onnxruntime: \(error.localizedDescription)")
        }
    }

    // MARK: - Loading

    private func load() throws -> Loaded {
        lock.lock(); defer { lock.unlock() }
        if let loaded { return loaded }
        guard GigaAMModelFiles.isPresent(in: modelDir) else { throw STTError.modelMissing(GigaAMModelFiles.directoryName) }
        do {
            let env = try ORTEnv(loggingLevel: .warning)
            func session(_ name: String) throws -> ORTSession {
                let options = try ORTSessionOptions()
                try options.setIntraOpNumThreads(Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))))
                // CPU execution provider only: no appendExecutionProvider call.
                return try ORTSession(env: env, modelPath: modelDir.appendingPathComponent(name).path, sessionOptions: options)
            }
            let vocabText = try String(contentsOf: modelDir.appendingPathComponent(GigaAMModelFiles.vocab), encoding: .utf8)
            var vocab: [String] = []
            for line in vocabText.split(separator: "\n") {
                // "<token> <id>"; the token itself may be "▁" or punctuation, never contains a space.
                guard let space = line.lastIndex(of: " "), let id = Int(line[line.index(after: space)...]) else { continue }
                if id >= vocab.count { vocab += [String](repeating: "", count: id - vocab.count + 1) }
                vocab[id] = String(line[..<space])
            }
            guard let blank = vocab.firstIndex(of: "<blk>") else { throw STTError.badResponse("gigaam vocab has no <blk>") }
            let l = Loaded(env: env, encoder: try session(GigaAMModelFiles.encoder),
                           decoder: try session(GigaAMModelFiles.decoder), joint: try session(GigaAMModelFiles.joint),
                           vocab: vocab, blank: blank)
            loaded = l
            return l
        } catch let e as STTError {
            throw e
        } catch {
            throw STTError.badResponse("onnxruntime load: \(error.localizedDescription)")
        }
    }

    // MARK: - Inference

    private static func tensor(_ floats: [Float], shape: [Int]) throws -> ORTValue {
        let data = floats.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: $0.count * 4) }
        return try ORTValue(tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
    }

    private static func tensor(int64 values: [Int64], shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: $0.count * 8) }
        return try ORTValue(tensorData: data, elementType: .int64, shape: shape.map { NSNumber(value: $0) })
    }

    private static func floats(_ value: ORTValue) throws -> [Float] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Returns encoder output as `[dim x frames]` row-major, the valid frame count and `dim`.
    private func runEncoder(_ m: Loaded, feats: [Float], frames: Int) throws -> ([Float], Int, Int) {
        let out = try m.encoder.run(
            withInputs: ["audio_signal": try Self.tensor(feats, shape: [1, GigaAMFeatures.mels, frames]),
                         "length": try Self.tensor(int64: [Int64(frames)], shape: [1])],
            outputNames: ["encoded", "encoded_len"], runOptions: nil)
        guard let encoded = out["encoded"], let lenValue = out["encoded_len"] else {
            throw STTError.badResponse("gigaam encoder returned no outputs")
        }
        let info = try encoded.tensorTypeAndShapeInfo()
        let shape = info.shape.map { $0.intValue }   // [1, dim, frames]
        guard shape.count == 3 else { throw STTError.badResponse("gigaam encoder shape \(shape)") }
        let lenData = try lenValue.tensorData() as Data
        let length = lenData.withUnsafeBytes { Int($0.bindMemory(to: Int32.self)[0]) }
        return (try Self.floats(encoded), min(length, shape[2]), shape[1])
    }

    private func greedyDecode(_ m: Loaded, enc: [Float], length: Int, dim: Int, frames: Int) throws -> [Int] {
        let hs = Self.hiddenSize
        var tokens: [Int] = []
        var h = [Float](repeating: 0, count: hs), c = [Float](repeating: 0, count: hs)
        // Decoder output for the current (last token, h, c), reused while only blanks come out.
        var cached: (dec: [Float], h: [Float], c: [Float])?
        var frame = [Float](repeating: 0, count: dim)
        var t = 0, emitted = 0
        while t < length {
            if cached == nil {
                let r = try m.decoder.run(
                    withInputs: ["x": try Self.tensor(int64: [Int64(tokens.last ?? m.blank)], shape: [1, 1]),
                                 "h.1": try Self.tensor(h, shape: [1, 1, hs]),
                                 "c.1": try Self.tensor(c, shape: [1, 1, hs])],
                    outputNames: ["dec", "h", "c"], runOptions: nil)
                guard let d = r["dec"], let nh = r["h"], let nc = r["c"] else { throw STTError.badResponse("gigaam decoder outputs") }
                cached = (try Self.floats(d), try Self.floats(nh), try Self.floats(nc))
            }
            for d in 0..<dim { frame[d] = enc[d * frames + t] }
            let j = try m.joint.run(
                withInputs: ["enc": try Self.tensor(frame, shape: [1, dim, 1]),
                             "dec": try Self.tensor(cached!.dec, shape: [1, hs, 1])],
                outputNames: ["joint"], runOptions: nil)
            guard let jv = j["joint"] else { throw STTError.badResponse("gigaam joint outputs") }
            let logits = try Self.floats(jv)
            var best = 0
            var bestV = -Float.infinity
            for (i, v) in logits.enumerated() where v > bestV { bestV = v; best = i }

            if best != m.blank {
                tokens.append(best)
                h = cached!.h; c = cached!.c
                cached = nil
                emitted += 1
            }
            if best == m.blank || emitted == Self.maxTokensPerStep {
                t += 1
                emitted = 0
            }
        }
        return tokens
    }
}

/// Splits long audio at quiet points so one encoder pass stays short (attention cost grows with length).
enum GigaAMChunker {
    static let maxSamples = 30 * AudioChunk.sampleRate
    static let searchSamples = 4 * AudioChunk.sampleRate
    static let blockSamples = AudioChunk.sampleRate / 10

    /// Cut points as `[start, end)` sample ranges covering the whole input.
    static func ranges(count: Int, samples: [Int16]) -> [Range<Int>] {
        guard count > maxSamples else { return count > 0 ? [0..<count] : [] }
        var out: [Range<Int>] = []
        var start = 0
        while start < count {
            var end = min(start + maxSamples, count)
            if end < count {
                var bestStart = end - searchSamples, bestEnergy = Int.max
                var s = end - searchSamples
                while s + blockSamples <= end {
                    var e = 0
                    for i in s..<(s + blockSamples) { e += abs(Int(samples[i])) }
                    if e < bestEnergy { bestEnergy = e; bestStart = s }
                    s += blockSamples / 2
                }
                end = bestStart + blockSamples / 2
            }
            out.append(start..<end)
            start = end
        }
        return out
    }
}

/// GigaAM on the Mac as a file recognizer (calls, "redo") — Russian speech.
public final class GigaAMLocal: FileTranscriber {
    public static let modelName = "gigaam-v3-e2e-rnnt-int8"
    public let engine: GigaAMEngine

    public init(modelDir: URL) { engine = GigaAMEngine(modelDir: modelDir) }

    public var isModelPresent: Bool { engine.isModelPresent }

    public func transcribe(_ file: URL, options: FileSTTOptions) async throws -> [TimedSegment] {
        let pcm = try WAVFile.readSamples(file)
        return try await transcribe(samples: pcm)
    }

    public func transcribe(samples pcm: [Int16]) async throws -> [TimedSegment] {
        var segments: [TimedSegment] = []
        for range in GigaAMChunker.ranges(count: pcm.count, samples: pcm) {
            let text = try await engine.transcribe(Array(pcm[range]))
            guard !text.isEmpty else { continue }
            segments.append(TimedSegment(startMs: range.lowerBound * 1000 / AudioChunk.sampleRate,
                                         endMs: range.upperBound * 1000 / AudioChunk.sampleRate, text: text))
        }
        return segments
    }
}

/// Dictation-style wrapper: buffers chunks and recognizes everything on `finish()`.
public final class GigaAMSpeechToText: SpeechToText {
    public let local: GigaAMLocal
    public var id: ProviderID { .gigaAM }

    public init(local: GigaAMLocal) { self.local = local }

    public func prewarm() async {
        // Loading takes a few hundred ms; failures surface later from begin()/finish().
        try? local.engine.warmUp()
    }

    public func begin(_ options: STTOptions) async throws -> any STTSession {
        guard local.isModelPresent else { throw STTError.modelMissing(GigaAMModelFiles.directoryName) }
        return GigaAMSession(local: local)
    }
}

final class GigaAMSession: STTSession, @unchecked Sendable {
    private let local: GigaAMLocal
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var cancelled = false

    init(local: GigaAMLocal) { self.local = local }

    var partials: AsyncStream<String> { AsyncStream { $0.finish() } }

    func append(_ chunk: AudioChunk) { lock.withLock { samples += chunk.samples } }

    func cancel() { lock.withLock { cancelled = true } }

    func finish() async throws -> Transcript {
        let (pcm, isCancelled) = lock.withLock { (samples, cancelled) }
        if isCancelled { throw STTError.cancelled }
        let text = try await local.engine.transcribe(pcm)
        return Transcript(text: text, language: nil, provider: .gigaAM, model: GigaAMLocal.modelName,
                          audioSeconds: Double(pcm.count) / Double(AudioChunk.sampleRate), networkMs: 0)
    }
}
