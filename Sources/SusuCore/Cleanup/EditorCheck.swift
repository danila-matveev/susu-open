import Foundation

/// Why the editor's answer was thrown away (spec 3.4 "проверка после модели").
public enum EditorRejection: Sendable, Equatable {
    /// Model answered with nothing.
    case empty
    /// Longer than the input by more than 30%.
    case tooLong
    /// Latin words that are neither in the input nor in the dictionary (Р5).
    case inventedLatin([String])
    /// A dictionary term stands where nothing similar-sounding was said (Р4).
    case unspokenTerm(String)
    /// Words changed beyond what the level allows (Д14).
    case changedWords(String)
}

/// Post-check of the editor output against the step-1 text. Pure; no model, no network.
enum EditorCheck {
    enum Verdict: Equatable {
        case accept(String)
        case reject(EditorRejection)
    }

    struct Token {
        var norm: String
        var raw: String
        var range: Range<String.Index>
    }

    /// Words = runs of letters and digits. Lowercased, ё = е, so "Telega.in" is `telega`, `in`.
    static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        var start: String.Index?
        var i = text.startIndex
        func close(_ end: String.Index) {
            if let s = start {
                let raw = String(text[s..<end])
                out.append(Token(norm: normalize(raw), raw: raw, range: s..<end))
                start = nil
            }
        }
        while i < text.endIndex {
            let c = text[i]
            if c.isLetter || c.isNumber { if start == nil { start = i } } else { close(i) }
            i = text.index(after: i)
        }
        close(text.endIndex)
        return out
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    static func isLatinWord(_ w: String) -> Bool {
        guard let f = w.unicodeScalars.first, f.value >= 97, f.value <= 122 else { return false }
        return w.unicodeScalars.allSatisfy { ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) }
    }

    /// Latin words of `output` that are in neither `input` nor the dictionary words (Р5).
    static func inventedLatin(input: String, output: String, terms: [String]) -> [String] {
        var known = Set(tokens(input).map(\.norm))
        for t in terms { known.formUnion(tokens(t).map(\.norm)) }
        var seen = Set<String>()
        return tokens(output).map(\.norm).filter { isLatinWord($0) && !known.contains($0) && seen.insert($0).inserted }
    }

    // MARK: - Sound similarity (Р4)

    private static let translit: [Character: String] = {
        let cyr = Array("абвгдеёжзийклмнопрстуфхцчшщъыьэюя")
        let lat = ["a", "b", "v", "g", "d", "e", "e", "zh", "z", "i", "i", "k", "l", "m", "n", "o", "p", "r", "s", "t",
                   "u", "f", "h", "ts", "ch", "sh", "sch", "", "y", "", "e", "yu", "ya"]
        return Dictionary(uniqueKeysWithValues: zip(cyr, lat))
    }()

    /// Consonant skeleton across scripts: "клод код" and "Claude Code" both give `kldkd`.
    static func skeleton(_ joined: String) -> String {
        var out = ""
        for ch in joined { out += translit[ch] ?? String(ch) }
        return out.replacingOccurrences(of: "c", with: "k").replacingOccurrences(of: "q", with: "k")
            .replacingOccurrences(of: "x", with: "ks").replacingOccurrences(of: "w", with: "v")
            .filter { !"aeiouy".contains($0) }
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var cur = [i + 1]
            for (j, y) in b.enumerated() {
                cur.append(min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (x == y ? 0 : 1)))
            }
            prev = cur
        }
        return prev[b.count]
    }

    static func ratio(_ a: String, _ b: String) -> Double {
        let (x, y) = (Array(a), Array(b))
        let m = max(x.count, y.count)
        return m == 0 ? 0 : Double(editDistance(x, y)) / Double(m)
    }

    /// True when `said` could be the spoken form of `written` (any script).
    static func soundsLike(_ said: String, _ written: String) -> Bool {
        guard !said.isEmpty else { return false }
        let (a, b) = (skeleton(said), skeleton(written))
        if a.isEmpty || b.isEmpty { return ratio(said, written) <= 0.34 }
        return ratio(a, b) <= 0.34
    }

    // MARK: - Alignment

    struct Hunk {
        var inRange: Range<Int>
        var outRange: Range<Int>
    }

    /// Word-level diff (LCS on normalized tokens): the places where input and output differ.
    static func hunks(_ a: [Token], _ b: [Token]) -> [Hunk] {
        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i].norm == b[j].norm ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var out: [Hunk] = []
        var i = 0, j = 0
        var hi = 0, hj = 0
        var open = false
        func flush() {
            if open { out.append(Hunk(inRange: hi..<i, outRange: hj..<j)); open = false }
        }
        while i < n || j < m {
            if i < n, j < m, a[i].norm == b[j].norm {
                flush(); i += 1; j += 1
            } else {
                if !open { open = true; hi = i; hj = j }
                if j >= m || (i < n && lcs[i + 1][j] >= lcs[i][j + 1]) { i += 1 } else { j += 1 }
            }
        }
        flush()
        return out
    }

    /// Can `s` be written as a sequence of dictionary terms? Returns the terms used.
    static func segment(_ s: String, terms: Set<String>, maxTerm: Int) -> [String]? {
        guard !s.isEmpty else { return nil }
        let chars = Array(s)
        var best = [[String]?](repeating: nil, count: chars.count + 1)
        best[0] = []
        for end in 1...chars.count {
            for start in max(0, end - maxTerm)..<end {
                guard let prefix = best[start] else { continue }
                let piece = String(chars[start..<end])
                if terms.contains(piece) { best[end] = prefix + [piece]; break }
            }
        }
        return best[chars.count]
    }

    // MARK: - Verdict

    static func verdict(input: String, output rawOutput: String, level: CleanupLevel, terms: [String]) -> Verdict {
        let output = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty { return .reject(.empty) }
        if Double(output.count) > Double(input.count) * 1.3 + 12 { return .reject(.tooLong) }
        let invented = inventedLatin(input: input, output: output, terms: terms)
        if !invented.isEmpty { return .reject(.inventedLatin(invented)) }

        let termNorms = Set(terms.map { tokens($0).map(\.norm).joined() }.filter { !$0.isEmpty })
        // A hunk may carry only a piece of a term ("Wiscro" -> "Wispr" inside "Wispr Flow"): allow whole-word pieces.
        var pieces = Set<String>()
        for t in terms {
            let words = tokens(t).map(\.norm)
            for i in words.indices { for j in (i + 1)...words.count { pieces.insert(words[i..<j].joined()) } }
        }
        pieces.remove("")
        let longest = termNorms.map(\.count).max() ?? 0
        let a = tokens(input), b = tokens(output)
        let diff = hunks(a, b)

        var edits: [(Range<String.Index>, String)] = []   // names level: term replacements applied onto the input
        for h in diff {
            let inStr = a[h.inRange].map(\.norm).joined()
            let outStr = b[h.outRange].map(\.norm).joined()
            let used = segment(outStr, terms: pieces, maxTerm: longest)

            // Р4: a dictionary term in the output needs similar-sounding words in the input.
            for term in termNorms where !term.isEmpty && outStr.contains(term) && !inStr.contains(term) {
                if !soundsLike(inStr, outStr) { return .reject(.unspokenTerm(term)) }
            }

            if let used, !used.isEmpty {
                // names level works on Latin product names only; a Cyrillic dictionary word ("Китаем" -> "Китай")
                // is an inflection risk, so that edit is simply not applied
                if level == .names, !outStr.unicodeScalars.contains(where: { $0.value >= 97 && $0.value <= 122 }) { continue }
                // whole hunk is dictionary terms: fine at every level; rebuilt onto the input for `names`
                if h.inRange.isEmpty { return .reject(.unspokenTerm(used[0])) }
                if !soundsLike(inStr, outStr) { return .reject(.unspokenTerm(used[0])) }
                if level == .names, let f = a[h.inRange].first, let l = a[h.inRange].last, let of = b[h.outRange].first, let ol = b[h.outRange].last {
                    edits.append((f.range.lowerBound..<l.range.upperBound, String(output[of.range.lowerBound..<ol.range.upperBound])))
                }
                continue
            }
            switch level {
            case .verbatim, .names:
                return .reject(.changedWords("\(inStr) -> \(outStr)"))
            case .normal:
                // same words, spelled a little differently at most (no rewording)
                if abs(h.inRange.count - h.outRange.count) > 1 || ratio(inStr, outStr) > 0.35 {
                    return .reject(.changedWords("\(inStr) -> \(outStr)"))
                }
            case .careful:
                break
            }
        }

        guard level == .names else { return .accept(output) }

        // Casing of a term that was already recognised ("claude code" -> "Claude Code").
        var termTokens = Set<String>()
        for t in terms { termTokens.formUnion(tokens(t).map(\.norm)) }
        var matched = Set<Int>()   // input token indexes covered by hunks
        for h in diff { matched.formUnion(h.inRange) }
        var j = 0
        for (i, tok) in a.enumerated() where !matched.contains(i) && termTokens.contains(tok.norm) {
            while j < b.count, b[j].norm != tok.norm { j += 1 }
            if j < b.count, b[j].raw != tok.raw, b[j].raw.contains(where: \.isUppercase) { edits.append((tok.range, b[j].raw)) }
            j += 1
        }

        var rebuilt = input
        for (range, text) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            rebuilt.replaceSubrange(range, with: text)
        }
        return .accept(rebuilt)
    }
}
