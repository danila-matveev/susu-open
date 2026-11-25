import Foundation

/// A dictionary replacement or snippet as plain values, so `CleanupRules` stays pure.
public struct RulesEntry: Sendable, Equatable {
    /// Reported back in `RulesResult.appliedReplacements` (the dictionary entry id; defaults to the phrase).
    public var id: String
    /// What the user says (whole word / whole phrase, case-insensitive).
    public var phrase: String
    /// What gets inserted. Inserted verbatim: never capitalised, never whitespace-normalised.
    public var replacement: String

    public init(id: String? = nil, phrase: String, replacement: String) {
        self.id = id ?? phrase
        self.phrase = phrase
        self.replacement = replacement
    }

    /// `nil` for entries without a replacement (plain `word` hints do nothing in step 1).
    public init?(_ entry: DictionaryEntry) {
        guard entry.deletedAt == nil, let r = entry.replacement, !entry.phrase.isEmpty else { return nil }
        self.init(id: entry.id, phrase: entry.phrase, replacement: r)
    }
}

public struct RulesOptions: Sendable {
    public var replacements: [RulesEntry]
    public var snippets: [RulesEntry]
    /// `false` for the "Дословно" level.
    public var capitalize: Bool
    public var voiceCommandsEnabled: Bool

    public init(replacements: [RulesEntry] = [], snippets: [RulesEntry] = [],
                capitalize: Bool = true, voiceCommandsEnabled: Bool = false) {
        self.replacements = replacements
        self.snippets = snippets
        self.capitalize = capitalize
        self.voiceCommandsEnabled = voiceCommandsEnabled
    }
}

public struct RulesResult: Sendable, Equatable {
    public var text: String
    /// A spoken "нажми Enter" / "отправь" ended the phrase: press Enter after inserting.
    public var pressEnter: Bool
    /// Ids of replacement and snippet entries that fired (each once), for use counters and the Д14 check.
    public var appliedReplacements: [String]
}

/// Step 1 of cleanup (spec 3.4): deterministic rules, no model, ~1 ms. Pure and iOS-safe.
public enum CleanupRules {
    public static func apply(_ input: String, options: RulesOptions = RulesOptions()) -> RulesResult {
        var text = input
        var applied: [String] = []
        var protected: [String] = []   // verbatim insertions, parked behind private-use placeholders

        text = removeFillers(text)
        text = collapseRepeats(text)
        text = substitute(options.replacements, in: text, protected: &protected, applied: &applied)
        text = substitute(options.snippets, in: text, protected: &protected, applied: &applied)
        text = stripHallucinations(text)

        var pressEnter = false
        if options.voiceCommandsEnabled {
            (text, pressEnter) = stripVoiceCommand(text)
        }

        text = normalizeWhitespace(text)
        if options.capitalize { text = capitalizeFirst(text) }
        text = restore(text, protected: protected)
        return RulesResult(text: text, pressEnter: pressEnter, appliedReplacements: applied)
    }

    // MARK: - Regex helpers

    private static let wordBefore = "(?<![\\p{L}\\p{N}_])"
    private static let wordAfter = "(?![\\p{L}\\p{N}_])"

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are static literals; a failure here is a programmer error caught by tests.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Rebuilds `text`, replacing every match with `transform`'s result (`nil` keeps the match).
    private static func replaceMatches(_ re: NSRegularExpression, in text: String,
                                       _ transform: (NSTextCheckingResult, NSString) -> String?) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let rep = transform(m, ns) else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += rep
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    // MARK: - Fillers and repeats

    // Not preceded by a letter, a "letter-" prefix or a number+space ("10 мм"); not followed by a letter or "-letter"
    // ("эмоция", "э-мейл"). A trailing comma or ellipsis goes with the filler.
    private static let fillerRegex = regex(
        wordBefore + "(?<![\\p{L}\\p{N}]-)(?<![0-9]\\s)(?:" + RulesLists.fillers.joined(separator: "|") + ")"
            + wordAfter + "(?!-[\\p{L}\\p{N}])(?:\\s*,|\\s*(?:\\.{3}|…))?")

    static func removeFillers(_ text: String) -> String {
        fillerRegex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                             withTemplate: "")
    }

    // Letters only: "10 10" is kept (could be a real number pair). Same line only; a comma between words keeps both.
    private static let repeatRegex = regex(wordBefore + "(\\p{L}+)[ \\t]+\\1" + wordAfter)

    static func collapseRepeats(_ text: String) -> String {
        var current = text
        for _ in 0..<8 {   // "я я я я" needs more than one pass
            let next = repeatRegex.stringByReplacingMatches(
                in: current, range: NSRange(location: 0, length: (current as NSString).length), withTemplate: "$1")
            if next == current { break }
            current = next
        }
        return current
    }

    // MARK: - Dictionary and snippets

    private static let placeholderBase: UInt32 = 0xE000   // private-use area, up to 6400 slots

    private static func phrasePattern(_ phrase: String) -> String? {
        let parts = phrase.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !parts.isEmpty else { return nil }
        let body = parts.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "\\s+")
        return wordBefore + body + wordAfter
    }

    /// Whole-word, case-insensitive replacement. Output is parked behind a placeholder so later steps
    /// (whitespace, capitalisation, command detection, further entries) cannot alter it.
    private static func substitute(_ entries: [RulesEntry], in text: String,
                                   protected: inout [String], applied: inout [String]) -> String {
        var current = text
        // Longest phrase first, so "open ai" wins over "open".
        let ordered = entries.enumerated().sorted {
            ($0.element.phrase.count, $1.offset) > ($1.element.phrase.count, $0.offset)
        }.map(\.element)
        for entry in ordered {
            guard let pattern = phrasePattern(entry.phrase),
                  let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            var fired = false
            current = replaceMatches(re, in: current) { _, _ in
                guard protected.count < 6400, let scalar = Unicode.Scalar(placeholderBase + UInt32(protected.count)) else {
                    return nil
                }
                protected.append(entry.replacement)
                fired = true
                return String(Character(scalar))
            }
            if fired, !applied.contains(entry.id) { applied.append(entry.id) }
        }
        return current
    }

    private static func restore(_ text: String, protected: [String]) -> String {
        guard !protected.isEmpty else { return text }
        var out = ""
        for ch in text.unicodeScalars {
            let v = ch.value
            if v >= placeholderBase, Int(v - placeholderBase) < protected.count {
                out += protected[Int(v - placeholderBase)]
            } else {
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    // MARK: - Whisper hallucinations

    private static let hallucinationRegex = regex(
        "(?:" + RulesLists.hallucinations.joined(separator: "|") + ")[\\s.!?…]*\\z")

    /// Removes a known hallucination only when it is a whole sentence at the very end.
    static func stripHallucinations(_ text: String) -> String {
        var current = text
        for _ in 0..<3 {
            let ns = current as NSString
            guard let m = hallucinationRegex.firstMatch(in: current, range: NSRange(location: 0, length: ns.length)) else {
                break
            }
            let before = ns.substring(to: m.range.location)
            let trimmed = before.trimmingTrailingWhitespace()
            let gap = before.dropFirst(trimmed.count)
            let atSentenceStart = trimmed.isEmpty || gap.contains("\n")
                || (trimmed.last.map { ".!?…\"»”)".contains($0) } ?? false)
            guard atSentenceStart else { break }
            current = trimmed
        }
        return current
    }

    // MARK: - Voice commands (end of phrase only)

    private static let commandRegex = regex(
        wordBefore + "(?:" + RulesLists.voiceCommands.joined(separator: "|") + ")[\\s.!?…,]*\\z")
    private static let danglingJoinRegex = regex("[\\s,;:\\-–—]*(?:\\s|^)(?:и|а|потом|затем|and|then)[\\s,]*\\z")

    static func stripVoiceCommand(_ text: String) -> (String, Bool) {
        let ns = text as NSString
        guard let m = commandRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return (text, false)
        }
        var rest = ns.substring(to: m.range.location)
        let ws = rest.trimmingTrailingWhitespace()
        // "…привет и отправь" -> "…привет": drop the dangling joiner and a dangling comma/dash.
        rest = ws
        let rns = rest as NSString
        if let j = danglingJoinRegex.firstMatch(in: rest, range: NSRange(location: 0, length: rns.length)) {
            rest = rns.substring(to: j.range.location)
        }
        while let last = rest.last, ",;:-–—".contains(last) || last.isWhitespace { rest.removeLast() }
        return (rest, true)
    }

    // MARK: - Whitespace and capitalisation

    private static let spacesRegex = regex("[ \\t\\x{00A0}]+")
    private static let spaceAroundNewlineRegex = regex("[ \\t]*\\n[ \\t]*")
    private static let spaceBeforePunctRegex = regex("[ \\t]+([,.!?;:…%)»])")

    static func normalizeWhitespace(_ text: String) -> String {
        var t = text
        for (re, template) in [(spacesRegex, " "), (spaceAroundNewlineRegex, "\n"), (spaceBeforePunctRegex, "$1")] {
            t = re.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length),
                                            withTemplate: template)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Uppercases the first letter, skipping leading quotes/brackets/dashes. Digits, placeholders stop the search.
    static func capitalizeFirst(_ text: String) -> String {
        let skip = "\"«„“‘'([-–—¿¡"
        var idx = text.startIndex
        while idx < text.endIndex, skip.contains(text[idx]) { idx = text.index(after: idx) }
        guard idx < text.endIndex, text[idx].isLetter else { return text }
        var out = text
        out.replaceSubrange(idx...idx, with: text[idx].uppercased())
        return out
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var s = self
        while let l = s.last, l.isWhitespace { s.removeLast() }
        return s
    }
}
