import Foundation

/// How much the editor may touch the text (spec 3.4); stored as a string in `Style.cleanupLevel`.
public enum CleanupLevel: String, Sendable, CaseIterable, Codable {
    /// Rules only, capitalization untouched.
    case verbatim
    /// Editor only swaps words for dictionary entries (350 ms timeout).
    case names
    /// Punctuation, paragraphs, style rule (1.5 s timeout).
    case normal
    /// Same as normal, more careful wording.
    case careful
}

extension Style {
    /// Unknown stored values read as `.normal`.
    public var level: CleanupLevel { CleanupLevel(rawValue: cleanupLevel) ?? .normal }
}

/// Picks the style for the place the user is dictating into (spec 1.6 «Стили»).
/// Priority: url > window title > app (bundle id) > default style.
public enum StyleResolver {
    public static func resolve(context: ContextSnapshot?, styles: [Style], rules: [StyleRule]) -> Style {
        let live = styles.filter { $0.deletedAt == nil }
        let byId = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        if let context {
            var best: (rank: Int, priority: Int, sort: Int, style: Style)?
            for rule in rules where rule.deletedAt == nil {
                guard let style = byId[rule.styleId], matches(rule, context) else { continue }
                let cand = (rank(rule.kind), rule.priority, style.sort, style)
                if let b = best {
                    let better = cand.0 != b.rank ? cand.0 > b.rank
                        : cand.1 != b.priority ? cand.1 > b.priority
                        : cand.2 != b.sort ? cand.2 < b.sort
                        : cand.3.id < b.style.id
                    if better { best = cand }
                } else { best = cand }
            }
            if let best { return best.style }
        }
        let ordered = live.sorted { ($0.sort, $0.id) < ($1.sort, $1.id) }
        return ordered.first { $0.isDefault } ?? ordered.first ?? fallback
    }

    /// Used only when the user has no styles at all.
    static let fallback = Style(id: "style-other", name: "Прочее", cleanupLevel: CleanupLevel.normal.rawValue, isDefault: true)

    private static func rank(_ kind: String) -> Int {
        switch kind { case "url": 3; case "title": 2; case "bundle": 1; default: 0 }
    }

    private static func matches(_ rule: StyleRule, _ ctx: ContextSnapshot) -> Bool {
        switch rule.kind {
        case "url":
            guard let url = ctx.url, !url.isEmpty else { return false }
            return globMatches(rule.pattern, normalizedURL(url))
        case "title":
            guard let title = ctx.windowTitle, !rule.pattern.isEmpty else { return false }
            return title.range(of: rule.pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case "bundle":
            return ctx.bundleID == rule.pattern
        default:
            return false
        }
    }

    /// Lower-cased, without scheme; a bare host gets a trailing `/` so `host/*` matches it.
    static func normalizedURL(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespaces).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if !s.contains("/") { s += "/" }
        return s
    }

    /// Case-insensitive glob, `*` = any run of characters (including none); everything else literal; whole-string match.
    static func globMatches(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.lowercased()), t = Array(text.lowercased())
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "*" { star = pi; mark = ti; pi += 1 }
            else if pi < p.count, p[pi] == t[ti] { pi += 1; ti += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; ti = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
