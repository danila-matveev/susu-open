import Foundation

/// One dictionary item read from someone else's file: a word, a replacement or a snippet.
public struct ImportedTerm: Equatable, Sendable, Hashable {
    /// `word` / `replacement` / `snippet` (same values as `dictionary_entry.kind`).
    public var kind: String
    public var phrase: String
    public var replacement: String?

    public init(kind: String, phrase: String, replacement: String? = nil) {
        self.kind = kind; self.phrase = phrase; self.replacement = replacement
    }

    static func word(_ p: String) -> ImportedTerm { ImportedTerm(kind: "word", phrase: p) }
    static func replacement(_ p: String, _ r: String) -> ImportedTerm { ImportedTerm(kind: "replacement", phrase: p, replacement: r) }
    static func snippet(_ p: String, _ r: String) -> ImportedTerm { ImportedTerm(kind: "snippet", phrase: p, replacement: r) }
}

/// Reads a word list in any of the shapes other dictation apps export (spec 6, docs/research/imports-competitors.md):
/// plain text (one per line, `a -> b` for replacements), CSV / TSV (with or without a header) and JSON
/// (array of strings, array of objects, `{from: to}` map, or those nested under container keys such as
/// `vocabulary`, `replacements`, `snippets`). The file formats of other apps are not documented, so parsing
/// is by shape, never by an exact schema: anything not understood goes into `notes`, nothing throws.
public enum DictionaryFileParser {
    public struct Result: Equatable, Sendable {
        public var terms: [ImportedTerm] = []
        /// Human-readable notes in Russian (what was skipped and why).
        public var notes: [String] = []
        /// Lines / items that were looked at but gave no term.
        public var skipped = 0
    }

    /// Files bigger than this are refused (a word list is kilobytes; 5 MB means the wrong file).
    public static let maxBytes = 5 * 1024 * 1024
    /// At most this many terms from one file.
    public static let maxTerms = 10_000
    /// Longest phrase kept for words and replacements (snippet bodies can be longer).
    static let maxPhraseLength = 200

    public static func parse(fileURL: URL) throws -> Result {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let size = attrs[.size] as? Int, size > maxBytes {
            return Result(notes: ["файл больше 5 МБ — это не похоже на словарь, пропущен"])
        }
        return parse(data: try Data(contentsOf: fileURL), fileExtension: fileURL.pathExtension)
    }

    public static func parse(data: Data, fileExtension: String) -> Result {
        guard data.count <= maxBytes else { return Result(notes: ["файл больше 5 МБ — это не похоже на словарь, пропущен"]) }
        guard let text = decode(data) else { return Result(notes: ["не удалось прочитать файл как текст"]) }
        let ext = fileExtension.lowercased()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: Result
        if ext == "json" || (ext != "csv" && ext != "tsv" && (trimmed.hasPrefix("{") || trimmed.hasPrefix("["))) {
            result = parseJSON(data: Data(trimmed.utf8))
        } else if ext == "csv" || ext == "tsv" {
            result = parseDelimited(text, ext: ext)
        } else {
            result = parsePlain(text)
        }
        return finish(result)
    }

    // MARK: Plain text

    static func parsePlain(_ text: String) -> Result {
        var r = Result()
        for raw in lines(text) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }
            if line.contains("\t") {
                let cells = line.components(separatedBy: "\t")
                add(phrase: cells[0], replacement: cells.count > 1 ? cells[1] : nil, to: &r)
                continue
            }
            if let arrow = ["->", "→", "=>"].lazy.compactMap({ line.range(of: $0) }).first {
                add(phrase: String(line[..<arrow.lowerBound]), replacement: String(line[arrow.upperBound...]), to: &r)
                continue
            }
            add(phrase: line, replacement: nil, to: &r)
        }
        return r
    }

    // MARK: CSV / TSV

    static let phraseHeaders: Set<String> = ["word", "words", "phrase", "term", "vocabulary", "original", "from", "find",
                                              "misspelling", "source", "spoken", "trigger", "key", "input", "pattern",
                                              "слово", "фраза", "было", "что"]
    static let replacementHeaders: Set<String> = ["replacement", "replace", "replacewith", "replace_with", "to", "correction",
                                                   "corrected", "target", "output", "value", "text", "expansion",
                                                   "замена", "стало", "на что"]

    static func parseDelimited(_ text: String, ext: String) -> Result {
        let firstLine = lines(text).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let delimiter: Character
        if ext == "tsv" || firstLine.contains("\t") { delimiter = "\t" }
        else if firstLine.filter({ $0 == ";" }).count > firstLine.filter({ $0 == "," }).count { delimiter = ";" }
        else { delimiter = "," }

        var rows = csvRows(text, delimiter: delimiter)
        rows.removeAll { $0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard !rows.isEmpty else { return Result(notes: ["файл пустой"]) }

        var phraseCol = 0
        var replacementCol: Int? = 1
        let header = rows[0].map(headerKey)
        let hp = header.firstIndex(where: { phraseHeaders.contains($0) })
        let hr = header.indices.first { $0 != hp && replacementHeaders.contains(header[$0]) }
        if hp != nil || hr != nil {
            phraseCol = hp ?? 0
            replacementCol = hr.flatMap { $0 == phraseCol ? nil : $0 }
            rows.removeFirst()
        }

        var r = Result()
        for row in rows {
            guard phraseCol < row.count else { r.skipped += 1; continue }
            let rep = replacementCol.flatMap { $0 < row.count ? row[$0] : nil }
            add(phrase: row[phraseCol], replacement: rep, to: &r)
        }
        return r
    }

    static func headerKey(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}\"")))
            .lowercased().replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "_")
    }

    /// RFC 4180: quoted cells, doubled quotes, newlines inside quotes.
    static func csvRows(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var quoted = false
        var chars = Array(text)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { cell.append("\""); i += 1 } else { quoted = false }
                } else { cell.append(c) }
            } else if c == "\"" && cell.trimmingCharacters(in: .whitespaces).isEmpty {
                cell = ""; quoted = true
            } else if c == delimiter {
                row.append(cell); cell = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(cell); rows.append(row); row = []; cell = ""
            } else {
                cell.append(c)
            }
            i += 1
        }
        if !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(row) }
        return rows
    }

    // MARK: JSON

    /// Keys that hold a list of plain words.
    static let wordContainerHints = ["vocab", "words", "terms", "dictionary", "custom_words", "customwords", "spellings"]
    /// Keys that hold replacements (`from -> to`).
    static let replacementContainerHints = ["replacement", "replace", "corrections", "substitution"]
    /// Keys that hold snippets (`trigger -> long text`).
    static let snippetContainerHints = ["snippet", "shortcut", "expansion", "textexpan"]
    /// Generic wrappers to look inside.
    static let wrapperHints = ["data", "items", "entries", "list", "values", "backup", "settings", "export"]

    static let objPhraseKeys = ["phrase", "word", "term", "original", "originaltext", "original_text", "from", "find",
                                "misspelling", "spoken", "source", "key", "trigger", "input", "pattern", "name", "text"]
    static let objReplacementKeys = ["replacement", "replacementtext", "replacement_text", "replacewith", "replace_with",
                                     "replace", "to", "correction", "corrected", "target", "output", "value", "expansion",
                                     "content", "body", "text"]
    static let objSnippetKeyPairs: [(String, String)] = [("name", "text"), ("trigger", "expansion"), ("trigger", "text"),
                                                          ("shortcut", "text"), ("shortcut", "expansion"), ("name", "content"),
                                                          ("trigger", "content"), ("keyword", "text"), ("abbreviation", "text")]

    enum Hint { case words, replacements, snippets, unknown }

    /// `rootMap`: a whole file that is one flat `{from: to}` object counts as replacements. Off when scanning
    /// another app's settings folder, where flat objects are usually settings, not words.
    static func parseJSON(data: Data, rootMap: Bool = true) -> Result {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return Result(notes: ["файл не читается как JSON"])
        }
        var r = Result()
        if rootMap, let dict = root as? [String: Any], !dict.isEmpty, dict.values.allSatisfy({ $0 is String }),
           !looksLikeOneObject(dict), !dict.keys.contains(where: { hint(forKey: $0) != nil }) {
            walk(dict, hint: .replacements, depth: 1, into: &r)
        } else {
            walk(root, hint: .unknown, depth: 0, into: &r)
        }
        if r.terms.isEmpty && r.notes.isEmpty {
            r.notes.append("в JSON не нашлось списка слов, замен или сниппетов")
        }
        return r
    }

    static func hint(forKey key: String) -> Hint? {
        let k = key.lowercased()
        if snippetContainerHints.contains(where: k.contains) { return .snippets }
        if replacementContainerHints.contains(where: k.contains) { return .replacements }
        if wordContainerHints.contains(where: k.contains) { return .words }
        if wrapperHints.contains(where: k.contains) { return .unknown }
        return nil
    }

    static func walk(_ node: Any, hint: Hint, depth: Int, into r: inout Result) {
        guard depth <= 6, r.terms.count < maxTerms else { return }
        if let array = node as? [Any] {
            for element in array { Self.item(element, hint: hint, depth: depth, into: &r) }
            return
        }
        guard let dict = node as? [String: Any] else { return }

        // A flat `{from: to}` map under a replacement/snippet key.
        if hint == .replacements || hint == .snippets, !dict.isEmpty, dict.values.allSatisfy({ $0 is String }), !looksLikeOneObject(dict) {
            for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
                guard let v = v as? String else { continue }
                if hint == .snippets { addSnippet(k, v, to: &r) } else { add(phrase: k, replacement: v, to: &r) }
            }
            return
        }
        if depth > 0, looksLikeOneObject(dict) {
            Self.item(dict, hint: hint, depth: depth, into: &r)
            return
        }
        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            guard let h = Self.hint(forKey: key) else { continue }
            walk(value, hint: h == .unknown ? hint : h, depth: depth + 1, into: &r)
        }
    }

    /// One element of a list.
    static func item(_ node: Any, hint: Hint, depth: Int, into r: inout Result) {
        if let s = node as? String {
            if hint == .replacements || hint == .snippets { r.skipped += 1; return }
            add(phrase: s, replacement: nil, to: &r)
            return
        }
        if let pair = node as? [Any], pair.count == 2, let a = pair[0] as? String, let b = pair[1] as? String {
            if hint == .snippets { addSnippet(a, b, to: &r) } else { add(phrase: a, replacement: b, to: &r) }
            return
        }
        guard let obj = node as? [String: Any] else {
            if node is [Any] { walk(node, hint: hint, depth: depth + 1, into: &r) } else { r.skipped += 1 }
            return
        }
        if isDisabled(obj) { r.skipped += 1; return }
        let lower = Dictionary(obj.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })

        for (pk, rk) in objSnippetKeyPairs where hint != .words && hint != .replacements {
            if let p = lower[pk] as? String, let t = lower[rk] as? String { addSnippet(p, t, to: &r); return }
        }
        guard let phraseKey = objPhraseKeys.first(where: { lower[$0] is String }), let phrase = lower[phraseKey] as? String else {
            // Not an item: maybe a container (e.g. `{ "vocabulary": [...] }` inside a list).
            if obj.keys.contains(where: { Self.hint(forKey: $0) != nil }) {
                walk(obj, hint: hint, depth: depth + 1, into: &r)
            } else {
                r.skipped += 1
            }
            return
        }
        let replacement = objReplacementKeys.first { $0 != phraseKey && lower[$0] is String }.flatMap { lower[$0] as? String }
        if hint == .snippets, let replacement {
            addSnippet(phrase, replacement, to: &r)
        } else {
            add(phrase: phrase, replacement: replacement, to: &r)
        }
    }

    /// `{ "word": "...", "replacement": "..." }`-like object rather than a `{from: to}` map.
    static func looksLikeOneObject(_ dict: [String: Any]) -> Bool {
        let keys = Set(dict.keys.map { $0.lowercased() })
        return !keys.isDisjoint(with: objPhraseKeys) || objSnippetKeyPairs.contains { keys.contains($0.0) && keys.contains($0.1) }
    }

    static func isDisabled(_ obj: [String: Any]) -> Bool {
        for (k, v) in obj {
            let key = k.lowercased()
            if ["enabled", "isenabled", "active", "isactive"].contains(key), let b = v as? Bool, !b { return true }
            if ["deleted", "isdeleted", "disabled", "isdisabled"].contains(key), let b = v as? Bool, b { return true }
        }
        return false
    }

    // MARK: Shared

    static func add(phrase: String, replacement: String?, to r: inout Result) {
        let p = clean(phrase)
        let rep = replacement.map(clean).flatMap { $0.isEmpty ? nil : $0 }
        guard !p.isEmpty, p.count <= maxPhraseLength else { r.skipped += 1; return }
        if let rep, rep != p {
            r.terms.append(.replacement(p, rep))
        } else {
            r.terms.append(.word(p))
        }
    }

    static func addSnippet(_ trigger: String, _ text: String, to r: inout Result) {
        let p = clean(trigger)
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, p.count <= maxPhraseLength, !t.isEmpty else { r.skipped += 1; return }
        r.terms.append(.snippet(p, t))
    }

    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
    }

    /// Drops exact duplicates inside the file (same kind and phrase, case-insensitive), caps the count.
    static func finish(_ input: Result) -> Result {
        var r = input
        var seen = Set<String>()
        var out: [ImportedTerm] = []
        var dupes = 0
        for t in r.terms {
            let key = t.kind + "\u{1}" + EditLearner.normalize(t.phrase)
            if seen.insert(key).inserted { out.append(t) } else { dupes += 1 }
        }
        if dupes > 0 { r.notes.append("повторы внутри файла: \(dupes) — взят первый") }
        if out.count > maxTerms {
            r.notes.append("в файле больше \(maxTerms) записей — взяты первые \(maxTerms)")
            out = Array(out.prefix(maxTerms))
        }
        r.terms = out
        return r
    }

    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .windowsCP1251)
    }

    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
    }
}
