// Finds what became of an inserted text after the user edited the field (T2.7).
public enum EditSpan {
    /// `field` = field value right after insertion, `later` = value now. The inserted text is located at its last
    /// occurrence in `field`; the text around it must be unchanged in `later`, else nil (ponytail: no fuzzy anchoring).
    /// Returns the edited version of `inserted`, or nil when nothing can be said.
    public static func edited(inserted: String, field: String, later: String) -> String? {
        guard !inserted.isEmpty, let r = field.range(of: inserted, options: .backwards) else { return nil }
        let prefix = field[..<r.lowerBound], suffix = field[r.upperBound...]
        guard later.count >= prefix.count + suffix.count, later.hasPrefix(prefix), later.hasSuffix(suffix) else { return nil }
        return String(later.dropFirst(prefix.count).dropLast(suffix.count))
    }
}
