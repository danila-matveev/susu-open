import Foundation
import SusuCore

/// Editor bench (T2.5): STT text -> rules -> editor, several models, per-clip text and editor ms.
enum EditorBench {
    struct Model {
        var name: String
        var provider: ProviderID
        var id: String
        /// Extra body fields that switch thinking off / low.
        var extra: [String: JSONValue]
    }

    /// Short list of fast models (spec 4.1). Names are what `--editor-models` takes.
    static let models: [Model] = [
        Model(name: "groq-gpt-oss-20b", provider: .groq, id: "openai/gpt-oss-20b", extra: ["reasoning_effort": .string("low")]),
        Model(name: "groq-gpt-oss-120b", provider: .groq, id: "openai/gpt-oss-120b", extra: ["reasoning_effort": .string("low")]),
        Model(name: "groq-qwen3.8-27b", provider: .groq, id: "qwen/qwen3.8-27b", extra: ["reasoning_effort": .string("none")]),
        Model(name: "or-glm-5.3-flash", provider: .openRouter, id: "z-ai/glm-5.3-flash", extra: ["reasoning": .object(["effort": .string("minimal")])]),
        Model(name: "or-qwen3.7-flash", provider: .openRouter, id: "qwen/qwen3.7-flash", extra: ["reasoning": .object(["enabled": .bool(false)])]),
        Model(name: "or-deepseek-v4.1-flash", provider: .openRouter, id: "deepseek/deepseek-v4.1-flash-1017", extra: ["reasoning": .object(["enabled": .bool(false)])]),
        Model(name: "or-haiku-5.5", provider: .openRouter, id: "anthropic/claude-haiku-5.5", extra: [:]),
    ]

    /// Copies of the default style rules (StyleDefaults is internal to SusuCore).
    static let stylePrompts: [String: (CleanupLevel, String)] = [
        "code": (.names, "Пиши слово в слово, как сказано. Ничего не перефразируй и не добавляй. Названия программ, библиотек и команд пиши латиницей, как они пишутся в коде."),
        "messengers": (.normal, "Короткие живые сообщения. Простая пунктуация, без официального тона. Не превращай реплику в длинный текст."),
    ]

    struct Dictionary {
        var words: [String]
        var replacements: [RulesEntry]
        var terms: [String] { words }
    }

    static func loadDictionary(set: String, path: String?) -> Dictionary {
        var words = TranscribeCommand.hintTerms("\(set)/hint.txt").map(\.term)
        var replacements: [RulesEntry] = []
        let file = path ?? "\(set)/dictionary.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            words += (obj["words"] as? [String]) ?? []
            for r in (obj["replacements"] as? [[String: String]]) ?? [] {
                if let p = r["phrase"], let t = r["replacement"] { replacements.append(RulesEntry(phrase: p, replacement: t)) }
            }
        } else {
            print("note: no \(file); using hint.txt only")
        }
        // unique, order kept; replacement targets are written forms too
        var seen = Set<String>()
        words = (words + replacements.map(\.replacement)).filter { $0.count > 1 && !$0.contains(",") && seen.insert($0.lowercased()).inserted }
        return Dictionary(words: Array(words.prefix(200)), replacements: replacements)
    }

    static func chat(for model: Model) -> any ChatLLM {
        let envName = model.provider == .groq ? "GROQ_API_KEY" : "OPENROUTER_API_KEY"
        guard let key = ProcessInfo.processInfo.environment[envName], !key.isEmpty else { TranscribeCommand.fail("\(envName) is not set") }
        let info = ProviderRegistry.builtIn.info(for: model.provider)!
        var profile: OpenAICompatibleChat.Profile = model.provider == .openRouter ? .openRouter() : .generic
        for (k, v) in model.extra { profile.extraBody[k] = v }
        return OpenAICompatibleChat(baseURL: URL(string: info.baseURL)!, apiKey: { key }, profile: profile)
    }

    struct ClipOut {
        var id: String
        var sttText: String
        var rulesText: String
        var result: EditorResult
        var sttSec: Double
        var cost: Double
        var rawRephrased: Bool
        var rawInventedLatin: [String]
    }

    /// `texts`: clip id -> (stt text, stt seconds). Returns the path written for each model.
    static func run(o: TranscribeCommand.Options, style: String, texts: [String: (text: String, sec: Double)]) async {
        guard let (level, rule) = stylePrompts[style] else { TranscribeCommand.fail("unknown style \(style) (code, messengers)") }
        let dict = loadDictionary(set: o.set, path: o.dictionary)
        print("style \(style) (level \(level.rawValue)), dictionary: \(dict.terms.count) terms, \(dict.replacements.count) replacements")
        let names = o.editorModels.isEmpty ? [models[0].name] : o.editorModels
        let ids = texts.keys.sorted()
        for name in names {
            guard let model = models.first(where: { $0.name == name }) else {
                TranscribeCommand.fail("unknown editor model \(name); known: \(models.map(\.name).joined(separator: ", "))")
            }
            let llm = chat(for: model)
            print("== \(name) (\(model.id))")
            // warm the connection like the key-down does in the app
            _ = try? await llm.complete(ChatRequest(model: model.id, messages: [.user("ok")], maxTokens: 8, timeout: 10, task: "editor"))
            var outs: [String: ClipOut] = [:]
            var next = 0
            let rulesOptions = RulesOptions(replacements: dict.replacements, capitalize: level != .verbatim)
            await withTaskGroup(of: ClipOut.self) { group in
                func launch() {
                    guard next < ids.count else { return }
                    let id = ids[next]; next += 1
                    let stt = texts[id]!
                    group.addTask {
                        let rules = CleanupRules.apply(stt.text, options: rulesOptions).text
                        var r = await Editor.edit(text: rules, level: level, context: EditorContext(styleRule: rule), terms: dict.terms,
                                                  chat: llm, model: model.id, timeout: o.editorTimeout)
                        // retries on a rate limit so the numbers are not polluted by throttling
                        var attempt = 0
                        while attempt < 5, case .failed(let why) = r.outcome, why.contains("rateLimited") {
                            attempt += 1
                            try? await Task.sleep(nanoseconds: 7_000_000_000)
                            r = await Editor.edit(text: rules, level: level, context: EditorContext(styleRule: rule), terms: dict.terms,
                                                  chat: llm, model: model.id, timeout: o.editorTimeout)
                        }
                        let cost = r.costUSD ?? ProviderRegistry.builtIn.estimateCost(provider: model.provider, model: model.id, tokensIn: promptTokens(rules, dict), tokensOut: rules.count / 2) ?? 0
                        var rawRephrased = false
                        var rawInvented: [String] = []
                        if let raw = r.modelText {
                            rawInvented = Editor.inventedLatinWords(input: rules, output: raw, terms: dict.terms)
                            if case .rejected(.changedWords) = r.outcome { rawRephrased = true }
                        }
                        return ClipOut(id: id, sttText: stt.text, rulesText: rules, result: r, sttSec: stt.sec, cost: cost,
                                       rawRephrased: rawRephrased, rawInventedLatin: rawInvented)
                    }
                }
                for _ in 0..<o.parallel { launch() }
                for await c in group { outs[c.id] = c; launch() }
            }
            write(outs, ids: ids, model: model, style: style, o: o)
            summarize(outs, ids: ids)
        }
    }

    static func promptTokens(_ text: String, _ dict: Dictionary) -> Int {
        (dict.terms.joined(separator: "\n").count + text.count + 700) / 3
    }

    static func write(_ outs: [String: ClipOut], ids: [String], model: Model, style: String, o: TranscribeCommand.Options) {
        var json: [String: [String: Any]] = [:]
        for id in ids {
            guard let c = outs[id] else { continue }
            var entry: [String: Any] = [
                "text": c.result.text,
                "sec": ((c.sttSec + Double(c.result.latencyMs) / 1000) * 100).rounded() / 100,
                "stt_text": c.sttText, "rules_text": c.rulesText,
                "editor_ms": c.result.latencyMs, "used": c.result.usedModel, "cost": c.cost,
                "outcome": describe(c.result.outcome),
            ]
            if let raw = c.result.modelText { entry["model_text"] = raw }
            json[id] = entry
        }
        let base = o.out ?? "runs/susu-editor-\(style).json"
        let full = base.hasPrefix("/") ? base : "\(o.set)/\(base)"
        let path = full.replacingOccurrences(of: ".json", with: "-\(model.name).json")
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
    }

    static func describe(_ o: EditorResult.Outcome) -> String {
        switch o {
        case .used: return "used"
        case .skipped: return "skipped"
        case .timedOut: return "timeout"
        case .failed(let why): return "failed: \(why.prefix(120))"
        case .rejected(let r): return "rejected: \(r)"
        }
    }

    static func summarize(_ outs: [String: ClipOut], ids: [String]) {
        func pct(_ xs: [Int], _ p: Double) -> Int { xs.isEmpty ? 0 : xs.sorted()[min(xs.count - 1, Int(Double(xs.count) * p))] }
        let ms = ids.compactMap { outs[$0]?.result.latencyMs }
        let used = outs.values.filter { $0.result.usedModel }.count
        let changed = outs.values.filter { $0.result.usedModel && $0.result.text != $0.rulesText }.count
        var reasons: [String: Int] = [:]
        for c in outs.values { reasons[describe(c.result.outcome).split(separator: "(").first.map(String.init) ?? "", default: 0] += 1 }
        let rephr = outs.values.filter(\.rawRephrased).count
        let invented = outs.values.filter { !$0.rawInventedLatin.isEmpty }.count
        let timeouts350 = ms.filter { $0 > 350 }.count
        print("editor ms: median \(pct(ms, 0.5)), p90 \(pct(ms, 0.9)), max \(ms.max() ?? 0); over 350 ms: \(timeouts350)/\(ms.count)")
        print("model answer used \(used)/\(outs.count), changed text in \(changed); raw answers that rephrased: \(rephr), raw answers with invented Latin: \(invented)")
        print("outcomes: \(reasons.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
        print(String(format: "cost per clip: $%.5f", outs.values.map(\.cost).reduce(0, +) / Double(max(1, outs.count))))
    }
}
