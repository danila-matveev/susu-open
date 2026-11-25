import Foundation
import SusuCore

/// Runs the clips of the test set through the real STT session API and writes
/// `{"c01": {"text": "...", "sec": 0.54}, ...}` (format of tools/stt-eval).
enum TranscribeCommand {
    struct Options {
        var set = ProcessInfo.processInfo.environment["SUSU_TESTSET"] ?? NSHomeDirectory() + "/Projects/susu/research-private/stt"
        var provider = "groq-turbo"
        var hintFile: String?
        var hintRaw = false
        var leadIn: String?
        var realtime = false
        var only: Set<String>?
        var out: String?
        var parallel = 4
        /// Editor bench (T2.5): run the editor of this style (code, messengers) on top of the STT text.
        var style: String?
        var editorModels: [String] = []
        var editorTimeout: TimeInterval = 10
        var dictionary: String?
        /// Reuse the texts of an earlier STT run instead of transcribing.
        var sttRun: String?
    }

    struct Clip { var id: String; var samples: [Int16] }

    static func parse(_ a: [String]) -> Options {
        var o = Options()
        var i = 0
        func value() -> String { i += 1; return i < a.count ? a[i] : "" }
        while i < a.count {
            switch a[i] {
            case "--set": o.set = value()
            case "--provider": o.provider = value()
            case "--hint": o.hintFile = value()
            case "--hint-raw": o.hintRaw = true
            case "--lead-in": o.leadIn = value()
            case "--realtime": o.realtime = true
            case "--only": o.only = Set(value().split(separator: ",").map(String.init))
            case "--out": o.out = value()
            case "--parallel": o.parallel = max(1, Int(value()) ?? 4)
            case "--style": o.style = value()
            case "--editor-models": o.editorModels = value().split(separator: ",").map(String.init)
            case "--editor-timeout": o.editorTimeout = TimeInterval(value()) ?? 10
            case "--dictionary": o.dictionary = value()
            case "--stt-run": o.sttRun = value()
            default: fail("unknown argument \(a[i])")
            }
            i += 1
        }
        return o
    }

    static func fail(_ m: String) -> Never {
        FileHandle.standardError.write(Data("error: \(m)\n".utf8)); exit(2)
    }

    static func provider(_ name: String) -> OpenAICompatibleTranscription {
        let model: String
        switch name {
        case "groq-turbo": model = "whisper-large-v3-turbo"
        case "groq-large": model = "whisper-large-v3"
        default: fail("unknown provider \(name) (groq-turbo, groq-large)")
        }
        guard let key = ProcessInfo.processInfo.environment["GROQ_API_KEY"], !key.isEmpty else { fail("GROQ_API_KEY is not set") }
        return OpenAICompatibleTranscription(model: model, keyProvider: { key })
    }

    /// hint.txt: optional "lead-in:" then comma-separated terms (same reading as tools/stt-eval/check.py).
    /// The lead-in is dropped: the builder never emits wrapper words.
    static func hintTerms(_ path: String) -> [HintTerm] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read hint file \(path)") }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = body.firstIndex(of: ":") { body = String(body[body.index(after: colon)...]) }
        let terms = body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
        // File order is the rank: first = most used.
        return terms.enumerated().map { HintTerm($0.element, useCount: terms.count - $0.offset) }
    }

    static func loadClips(_ o: Options) -> [Clip] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(o.set)/clips/clips.json")),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { fail("cannot read \(o.set)/clips/clips.json") }
        var out: [Clip] = []
        for item in list {
            guard let id = item["id"] as? String, o.only?.contains(id) ?? true else { continue }
            guard let wav = try? Data(contentsOf: URL(fileURLWithPath: "\(o.set)/clips/\(id).wav")),
                  let d = WAV.decode(wav), d.sampleRate == 16_000, d.channels == 1 else { fail("\(id).wav is not 16 kHz mono 16-bit") }
            out.append(Clip(id: id, samples: d.samples))
        }
        return out
    }

    static func run(_ a: [String]) async {
        let o = parse(a)
        if let style = o.style, let run = o.sttRun {
            let path = run.hasPrefix("/") ? run : "\(o.set)/\(run)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { fail("cannot read STT run \(path)") }
            var texts: [String: (text: String, sec: Double)] = [:]
            for (id, v) in obj where o.only?.contains(id) ?? true { texts[id] = (v["text"] as? String ?? "", (v["sec"] as? NSNumber)?.doubleValue ?? 0) }
            await EditorBench.run(o: o, style: style, texts: texts)
            return
        }
        let stt = provider(o.provider)
        let hint: STTHint
        if o.hintRaw {
            let raw = (try? String(contentsOfFile: o.hintFile ?? "\(o.set)/hint.txt", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            hint = STTHint(terms: [], prompt: raw)
        } else {
            hint = STTHintBuilder.build(terms: hintTerms(o.hintFile ?? "\(o.set)/hint.txt"), leadIn: o.leadIn)
        }
        print("hint (\(hint.terms.count) terms): \(hint.prompt)")
        let clips = loadClips(o)
        await stt.prewarm()

        var results: [String: (text: String, sec: Double)] = [:]
        if o.realtime {
            var next = 0
            await withTaskGroup(of: (String, String, Double).self) { group in
                func launch() {
                    guard next < clips.count else { return }
                    let c = clips[next]; next += 1
                    group.addTask { await transcribe(c, stt: stt, hint: hint, realtime: true) }
                }
                for _ in 0..<o.parallel { launch() }
                for await (id, text, sec) in group {
                    results[id] = (text, sec); report(id, text, sec); launch()
                }
            }
        } else {
            for c in clips {
                let (id, text, sec) = await transcribe(c, stt: stt, hint: hint, realtime: false)
                results[id] = (text, sec); report(id, text, sec)
            }
        }

        var json: [String: [String: Any]] = [:]
        for (id, r) in results { json[id] = ["text": r.text, "sec": (r.sec * 100).rounded() / 100] }
        let data = try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if let out = o.out {
            let path = out.hasPrefix("/") ? out : "\(o.set)/\(out)"
            try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try! data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
        summary(clips, results)
        if let style = o.style {
            await EditorBench.run(o: o, style: style, texts: results.mapValues { ($0.text, $0.sec) })
        }
    }

    static func report(_ id: String, _ text: String, _ sec: Double) {
        print(String(format: "%@ %.2fs %@", id, sec, String(text.prefix(70))))
    }

    /// One clip through the session API. `sec` = from the end of the audio (realtime) or from the start of
    /// sending (batch) to the finished text.
    static func transcribe(_ c: Clip, stt: OpenAICompatibleTranscription, hint: STTHint, realtime: Bool) async -> (String, String, Double) {
        let options = STTOptions(language: .auto, hint: hint)
        for attempt in 0..<4 {
            do {
                if realtime { await stt.prewarm() }   // what the key-down does
                let detector = BenchPauseDetector()
                let pause: (@Sendable (AudioChunk) -> Bool)? = realtime ? { @Sendable chunk in detector.pauseEnded(chunk) } : nil
                let session = try stt.begin(options, pauseEnded: pause)
                var t0 = ContinuousClock.now
                let chunkSamples = AudioChunk.samplesPer40ms
                if realtime {
                    let start = ContinuousClock.now
                    var n = 0
                    var i = 0
                    while i < c.samples.count {
                        let end = min(i + chunkSamples, c.samples.count)
                        // a chunk is available once its audio has been spoken
                        try? await Task.sleep(until: start + .milliseconds((n + 1) * 40), clock: .continuous)
                        session.append(AudioChunk(samples: Array(c.samples[i..<end]), startMs: n * 40))
                        i = end; n += 1
                    }
                    t0 = ContinuousClock.now
                } else {
                    var i = 0, n = 0
                    while i < c.samples.count {
                        let end = min(i + chunkSamples, c.samples.count)
                        session.append(AudioChunk(samples: Array(c.samples[i..<end]), startMs: n * 40))
                        i = end; n += 1
                    }
                    t0 = ContinuousClock.now
                }
                let t = try await session.finish()
                let d = ContinuousClock.now - t0
                let sec = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
                return (c.id, t.text, sec)
            } catch let e as STTError where e == .rateLimited && attempt < 3 {
                try? await Task.sleep(nanoseconds: 8_000_000_000)   // retry, not part of the measured time
            } catch {
                FileHandle.standardError.write(Data("\(c.id): \(error)\n".utf8))
                return (c.id, "", 0)
            }
        }
        return (c.id, "", 0)
    }

    static func summary(_ clips: [Clip], _ r: [String: (text: String, sec: Double)]) {
        func median(_ xs: [Double]) -> String { xs.isEmpty ? "-" : String(format: "%.2f", xs.sorted()[xs.count / 2]) }
        let secs = clips.compactMap { c in r[c.id].flatMap { $0.sec > 0 ? $0.sec : nil } }
        let short = clips.filter { $0.samples.count <= 15 * 16_000 }.compactMap { r[$0.id]?.sec }.filter { $0 > 0 }
        let long = clips.filter { $0.samples.count > 45 * 16_000 }.compactMap { r[$0.id]?.sec }.filter { $0 > 0 }
        let failed = clips.filter { (r[$0.id]?.sec ?? 0) == 0 }.map(\.id)
        print("median all \(median(secs)) s | clips <= 15 s: \(median(short)) s (n=\(short.count)) | clips > 45 s: \(median(long)) s (n=\(long.count))")
        if !failed.isEmpty { print("FAILED: \(failed.joined(separator: ", "))") }
    }
}

/// Bench-only energy detector (the app uses the audio module's PauseDetector).
/// true = speech resumed after at least 320 ms of silence.
final class BenchPauseDetector: @unchecked Sendable {
    private var floor = 1e9
    private var silentRun = 0

    func pauseEnded(_ chunk: AudioChunk) -> Bool {
        guard !chunk.samples.isEmpty else { return false }
        var sum = 0.0
        for s in chunk.samples { sum += Double(s) * Double(s) }
        let rms = (sum / Double(chunk.samples.count)).squareRoot()
        floor = min(rms, floor * 1.02 + 0.5)   // slowly rising noise floor
        if rms < max(floor * 3, 200) { silentRun += 1; return false }
        defer { silentRun = 0 }
        return silentRun >= 8
    }
}
