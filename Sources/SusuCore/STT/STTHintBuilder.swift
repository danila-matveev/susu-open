import Foundation

/// A dictionary entry as the hint builder sees it.
public struct HintTerm: Sendable, Equatable {
    public var term: String
    public var starred: Bool
    public var useCount: Int
    public init(_ term: String, starred: Bool = false, useCount: Int = 0) {
        self.term = term; self.starred = starred; self.useCount = useCount
    }
}

/// Builds the Whisper `prompt` (spec 3.3): terms separated by commas, no wrapper words in any language
/// (a Russian lead-in pulls other languages into Russian), at most 224 Whisper tokens.
///
/// Order: starred, then use count (high first), then words from the window title.
/// Terms that would hurt are dropped (R4: a dictionary word must not show up where it was not said):
/// duplicates and near-duplicates (the higher-ranked one stays), groups of sound-alike terms
/// (Telegram / Telega.in / TELOWAY: all dropped unless starred), and terms too generic to need a hint.
public enum STTHintBuilder {
    public static let maxTokens = 224

    /// Conservative token estimate without a tokenizer: Latin 1 token per 3 chars, Cyrillic per 2,
    /// anything else (CJK, etc.) 1 per char, rounded up per term, plus 1 for the ", " separator.
    /// Real Whisper BPE is usually shorter, so the 224 limit is never exceeded.
    public static func estimatedTokens(_ term: String) -> Int {
        var latin = 0, cyr = 0, other = 0
        for u in term.unicodeScalars {
            switch u.value {
            case 0x20...0x24F: latin += 1
            case 0x400...0x4FF: cyr += 1
            default: other += 1
            }
        }
        return (latin + 2) / 3 + (cyr + 1) / 2 + other + 1
    }

    /// `leadIn` is off by default (spec 3.3: no wrapper words). On the 50 dictations an English lead-in
    /// ("Work dictation with product names:") lifts the name hit rate by about 9 points and leaves the 15-language
    /// check unchanged; it is a switch for the orchestrator to decide on, see the T1.3 report.
    public static func build(terms: [HintTerm], windowTitle: String? = nil, leadIn: String? = nil,
                             maxTokens: Int = maxTokens) -> STTHint {
        var ranked = terms.enumerated().sorted {
            if $0.element.starred != $1.element.starred { return $0.element.starred }
            if $0.element.useCount != $1.element.useCount { return $0.element.useCount > $1.element.useCount }
            return $0.offset < $1.offset
        }.map(\.element.term)
        ranked += titleWords(windowTitle)

        var candidates: [String] = []
        for raw in ranked {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, !isGeneric(term), !candidates.contains(where: { nearDuplicate($0, term) }) else { continue }
            candidates.append(term)
        }
        // Sound-alike terms pull each other into the wrong place (R4: Telega.in said, TELOWAY written),
        // so none of them goes in unless the user starred it.
        let starred = Set(terms.filter(\.starred).map(\.term))
        let all = candidates
        candidates = all.filter { t in starred.contains(t) || !all.contains { $0 != t && confusable($0, t) } }

        var kept: [String] = []
        var used = leadIn.map { estimatedTokens($0) + 1 } ?? 0
        for term in candidates {
            let cost = estimatedTokens(term)
            guard used + cost <= maxTokens else { continue }   // a shorter one further down may still fit
            kept.append(term); used += cost
        }
        guard let leadIn, !kept.isEmpty else { return STTHint(terms: kept, prompt: kept.joined(separator: ", ")) }
        return STTHint(terms: kept, prompt: "\(leadIn) \(kept.joined(separator: ", ")).")
    }

    /// Words of the window title that look like names (3+ chars, not numbers), as hint candidates.
    static func titleWords(_ title: String?) -> [String] {
        guard let title else { return [] }
        let words = title.split { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".-")) }
        return words.filter { $0.count >= 3 && !$0.allSatisfy(\.isNumber) }
    }

    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "this", "that", "from", "you", "your", "are", "was", "not", "but",
        "app", "new", "untitled", "window", "file", "edit", "view", "help", "http", "https", "www", "com",
        "это", "как", "что", "для", "или", "при", "все", "так", "его", "она", "они", "мне", "там", "тут",
    ]

    static func isGeneric(_ term: String) -> Bool {
        let key = fold(term)
        return key.count < 2 || key.allSatisfy(\.isNumber) || stopwords.contains(term.lowercased())
    }

    /// Lowercase letters and digits only: "Telega.in" and "telega in" compare equal.
    static func fold(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Same word, or one typo away (long terms only), or one contains the other as a prefix
    /// ("Telega" / "Telega.in"). Terms sharing only a first syllable ("Telegram" / "TELOWAY") are not near.
    static func nearDuplicate(_ a: String, _ b: String) -> Bool {
        let x = fold(a), y = fold(b)
        if x == y { return true }
        guard min(x.count, y.count) >= 4 else { return false }
        if x.hasPrefix(y) || y.hasPrefix(x) { return true }
        return max(x.count, y.count) >= 6 && editDistance(Array(x), Array(y)) <= 1
    }

    /// Different words that start alike (same first three letters, both 5+ letters): Telegram / Telega.in / TELOWAY.
    static func confusable(_ a: String, _ b: String) -> Bool {
        let x = fold(a), y = fold(b)
        return x.count >= 5 && y.count >= 5 && x.prefix(3) == y.prefix(3)
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var prev = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var cur = [i]
            for j in 1...max(b.count, 1) where !b.isEmpty {
                cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
