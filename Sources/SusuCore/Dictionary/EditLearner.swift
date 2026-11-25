import Foundation

/// One differing span between inserted and edited text (spec 3.7).
public struct EditCandidate: Sendable, Hashable {
    /// What the recognizer wrote (empty when the user only inserted words).
    public var before: String
    /// What the user typed instead.
    public var after: String
    /// `before` is non-empty and looks like a mishearing of `after` (other script, or a few letters apart).
    /// The judge decides finally.
    public var isReplacement: Bool

    public init(before: String, after: String, isReplacement: Bool) {
        self.before = before; self.after = after; self.isReplacement = isReplacement
    }

    /// Case-insensitive identity used to merge repeats.
    var key: String { EditLearner.normalize(before) + "\u{1F}" + EditLearner.normalize(after) }
}

public enum JudgeVerdict: String, Sendable, Codable {
    case newWord = "new_word"
    case recognitionFix = "recognition_fix"
    case rewrite
}

public struct JudgedCandidate: Sendable, Equatable {
    public var candidate: EditCandidate
    public var verdict: JudgeVerdict
    /// How many edits produced this candidate (batch mode); 1 for a live edit.
    public var count: Int
    public var isAccepted: Bool { verdict != .rewrite }

    public init(candidate: EditCandidate, verdict: JudgeVerdict, count: Int = 1) {
        self.candidate = candidate; self.verdict = verdict; self.count = count
    }
}

/// Learns words from the user's corrections: word-level diff -> candidates -> judge model -> dictionary.
public enum EditLearner {
    /// Longest differing span (in words, either side) that can become a candidate.
    public static let maxSpanWords = 4

    // MARK: Candidates (pure)

    public static func candidates(inserted: String, edited: String, known: Set<String> = []) -> [EditCandidate] {
        let a = tokens(inserted), b = tokens(edited)
        let known = Set(known.map(normalize))
        var out: [EditCandidate] = []
        var seen = Set<String>()
        for span in diffSpans(a, b) {
            guard span.after.count > 0, span.before.count <= maxSpanWords, span.after.count <= maxSpanWords else { continue }
            let afterWords = span.after.map(\.surface)
            if afterWords.allSatisfy({ stopWords.contains(normalize($0)) || $0.count < 2 }) { continue }
            let before = span.before.map(\.surface).joined(separator: " ")
            let after = afterWords.joined(separator: " ")
            let isReplacement = !before.isEmpty && looksLikeMishearing(before, after)
            let nb = normalize(before), na = normalize(after)
            if !before.isEmpty, known.contains(nb) { continue }
            if known.contains(na), !isReplacement { continue }
            let c = EditCandidate(before: before, after: after, isReplacement: isReplacement)
            if seen.insert(c.key).inserted { out.append(c) }
        }
        return out
    }

    // MARK: Judge

    /// One JSON-schema request for all candidates: «new word / recognition fix» vs «just rewrote».
    /// A candidate the model does not mention counts as a rewrite.
    public static func judge(_ candidates: [EditCandidate], llm: any ChatLLM, model: String,
                             timeout: TimeInterval = 15) async throws -> [JudgedCandidate] {
        try await judgeWeighted(candidates.map { ($0, 1) }, llm: llm, model: model, timeout: timeout)
    }

    static func judgeWeighted(_ items: [(EditCandidate, Int)], llm: any ChatLLM, model: String,
                      timeout: TimeInterval = 15) async throws -> [JudgedCandidate] {
        guard !items.isEmpty else { return [] }
        var lines = ""
        for (i, item) in items.enumerated() {
            lines += "\(i). before: \(jsonString(item.0.before)) -> after: \(jsonString(item.0.after))\n"
        }
        let request = ChatRequest(
            model: model,
            messages: [.system(judgePrompt), .user(lines)],
            jsonSchema: ("edit_verdicts", judgeSchema),
            temperature: 0, maxTokens: 40 + items.count * 24, timeout: timeout, task: "judge")
        let response = try await llm.complete(request)
        let verdicts = parseVerdicts(response.text)
        return items.enumerated().map { i, item in
            JudgedCandidate(candidate: item.0, verdict: verdicts[i] ?? .rewrite, count: item.1)
        }
    }

    static let judgeSchema = """
        {"type":"object","properties":{"results":{"type":"array","items":{"type":"object","properties":{\
        "id":{"type":"integer"},"verdict":{"type":"string","enum":["new_word","recognition_fix","rewrite"]}},\
        "required":["id","verdict"],"additionalProperties":false}}},"required":["results"],"additionalProperties":false}
        """

    static let judgePrompt = """
        You review corrections a user made to text that a speech recognizer typed for them (Russian and English mixed). \
        For each numbered line, "before" is what the recognizer wrote (may be empty) and "after" is what the user \
        typed instead. Answer with one verdict per line:
        - "recognition_fix": the recognizer misheard a name, term or word and the user corrected the spelling \
        (the sound is similar, e.g. "клод код" -> "Claude Code").
        - "new_word": the user added a name, term or word worth remembering (a proper noun, brand, jargon).
        - "rewrite": the user just changed wording, tone, grammar or meaning; nothing to remember.
        Reply only with JSON: {"results":[{"id":0,"verdict":"..."}]}.
        """

    static func parseVerdicts(_ text: String) -> [Int: JudgeVerdict] {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let l = s.firstIndex(of: "{"), let r = s.lastIndex(of: "}"), l < r { s = String(s[l...r]) }
        struct Payload: Decodable { struct Item: Decodable { var id: Int; var verdict: String }; var results: [Item] }
        guard let data = s.data(using: .utf8), let p = try? JSONDecoder().decode(Payload.self, from: data) else { return [:] }
        var out: [Int: JudgeVerdict] = [:]
        for item in p.results { if let v = JudgeVerdict(rawValue: item.verdict) { out[item.id] = v } }
        return out
    }

    private static func jsonString(_ s: String) -> String {
        guard let d = try? JSONEncoder().encode(s), let r = String(data: d, encoding: .utf8) else { return "\"\"" }
        return r
    }

    // MARK: Apply

    /// Adds accepted candidates as dictionary entries with `origin`. A new word becomes a `word` entry. A recognition fix
    /// becomes a `replacement` (before -> after) when the same distortion repeats (`count` >= 2) or the target word is
    /// already in the dictionary; otherwise it becomes a `word` entry for `after`. Rewrites are skipped.
    @discardableResult
    public static func apply(_ judged: [JudgedCandidate], to dictionary: DictionaryService,
                             origin: String = "learned", now: Date = Date()) async throws -> [DictionaryEntry] {
        var known = try await dictionary.knownPhrases()
        var added: [DictionaryEntry] = []
        for j in judged where j.isAccepted {
            let c = j.candidate
            let afterKnown = known.contains(normalize(c.after))
            let asReplacement = j.verdict == .recognitionFix && !c.before.isEmpty && c.isReplacement
                && (j.count >= 2 || afterKnown)
            if asReplacement {
                if known.contains(normalize(c.before)) { continue }
                added.append(try await dictionary.add(kind: DictionaryService.Kind.replacement, phrase: c.before,
                                                      replacement: c.after, origin: origin, now: now))
                known.insert(normalize(c.before))
            } else if !afterKnown {
                added.append(try await dictionary.add(kind: DictionaryService.Kind.word, phrase: c.after,
                                                      origin: origin, now: now))
                known.insert(normalize(c.after))
            }
        }
        return added
    }

    // MARK: Diff internals

    struct Token { var surface: String; var norm: String }
    struct Span { var before: [Token]; var after: [Token] }

    static let edgePunctuation = CharacterSet(charactersIn: ".,!?;:\"'«»“”„‘’()[]{}…—–-/\\*_`")

    static func tokens(_ text: String) -> [Token] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { raw in
            let surface = String(raw).trimmingCharacters(in: edgePunctuation)
            guard !surface.isEmpty else { return nil }
            return Token(surface: surface, norm: normalize(surface))
        }
    }

    /// Lowercase, `ё` = `е`, trimmed of edge punctuation: the form words are compared in.
    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: edgePunctuation.union(.whitespacesAndNewlines))
            .lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    /// Word-level Levenshtein alignment; consecutive non-matching steps form one span.
    static func diffSpans(_ a: [Token], _ b: [Token]) -> [Span] {
        var lo = 0
        while lo < a.count, lo < b.count, a[lo].norm == b[lo].norm { lo += 1 }
        var hiA = a.count, hiB = b.count
        while hiA > lo, hiB > lo, a[hiA - 1].norm == b[hiB - 1].norm { hiA -= 1; hiB -= 1 }
        let x = Array(a[lo..<hiA]), y = Array(b[lo..<hiB])
        if x.isEmpty && y.isEmpty { return [] }
        // Both sides differ wildly: a rewrite, never a candidate (also bounds the matrix).
        if x.count > 1500 || y.count > 1500 { return [] }
        let n = x.count, m = y.count, w = m + 1
        var d = [Int32](repeating: 0, count: (n + 1) * w)
        for i in 0...n { d[i * w] = Int32(i) }
        for j in 0...m { d[j] = Int32(j) }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let sub = d[(i - 1) * w + j - 1] + (x[i - 1].norm == y[j - 1].norm ? 0 : 1)
                    d[i * w + j] = min(sub, d[(i - 1) * w + j] + 1, d[i * w + j - 1] + 1)
                }
            }
        }
        // Backtrace (prefers match, then substitution), then group forward.
        enum Op { case match, sub, del, ins }
        var ops: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, x[i - 1].norm == y[j - 1].norm, d[i * w + j] == d[(i - 1) * w + j - 1] {
                ops.append(.match); i -= 1; j -= 1
            } else if i > 0, j > 0, d[i * w + j] == d[(i - 1) * w + j - 1] + 1 {
                ops.append(.sub); i -= 1; j -= 1
            } else if i > 0, d[i * w + j] == d[(i - 1) * w + j] + 1 {
                ops.append(.del); i -= 1
            } else {
                ops.append(.ins); j -= 1
            }
        }
        ops.reverse()
        var spans: [Span] = []
        var cur = Span(before: [], after: [])
        var xi = 0, yi = 0
        func flush() {
            if !cur.before.isEmpty || !cur.after.isEmpty { spans.append(cur); cur = Span(before: [], after: []) }
        }
        for op in ops {
            switch op {
            case .match: flush(); xi += 1; yi += 1
            case .sub: cur.before.append(x[xi]); cur.after.append(y[yi]); xi += 1; yi += 1
            case .del: cur.before.append(x[xi]); xi += 1
            case .ins: cur.after.append(y[yi]); yi += 1
            }
        }
        flush()
        return spans
    }

    // MARK: Mishearing heuristic

    static func looksLikeMishearing(_ before: String, _ after: String) -> Bool {
        let b = normalize(before), a = normalize(after)
        if scripts(b) != scripts(a) { return true }
        let dist = charDistance(Array(b), Array(a))
        return Double(dist) / Double(max(b.count, a.count, 1)) <= 0.4
    }

    /// Which of Cyrillic / Latin / digits the text uses; a change of this set means the spelling moved to another "world".
    private static func scripts(_ s: String) -> [Bool] {
        let u = s.unicodeScalars
        return [u.contains { (0x0400...0x04FF).contains($0.value) },
                u.contains { ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A) },
                u.contains { $0.value >= 0x30 && $0.value <= 0x39 }]
    }

    private static func charDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1), prev[j] + 1, cur[j - 1] + 1)
            }
            prev = cur
        }
        return prev[b.count]
    }

    // MARK: Stop words

    static let stopWords: Set<String> = Set("""
        и в во не что он на я с со как а то все она так его но да ты к у же вы за бы по только ее мне было вот от меня \
        еще нет о из ему теперь когда даже ну вдруг ли если уже или ни быть был него до вас нибудь опять уж вам сказал \
        ведь там потом себя ничего ей может они тут где есть надо ней для мы тебя их чем была сам чтоб без будто чего \
        раз тоже себе под будет ж тогда кто этот того потому этого какой совсем ним здесь этом один почти мой тем чтобы \
        нее сейчас были куда зачем всех никогда можно при наконец два об другой хоть после над больше тот через эти \
        нас про всего них какая много разве три эту моя впрочем хорошо свою этой перед иногда лучше чуть том нельзя \
        такой им более всегда конечно всю между это тоже просто ещё
        the a an and or but of to in on at for with by from as is are was were be been it its this that these those \
        i you he she we they me my your our their not no so if then than do does did have has had will would can \
        could should just also very
        """.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\\" }).map { normalize(String($0)) })
}
