import Foundation

/// Pure, cross-platform helpers for the context snapshot (spec 2.5, 7, 9.6).
public enum ContextRules {
    public static let maxTextBeforeCursor = 500
    /// Selected text is capped so a "select all" in a huge document cannot stall the snapshot.
    public static let maxSelectedText = 20_000

    /// Default exclusion list (spec 7): password managers and a few banks. Editable in settings later.
    public static let defaultExclusions: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.apple.keychainaccess", "org.keepassxc.keepassxc",
        "com.lastpass.lastpassmacdesktop", "com.apple.Passwords",
        // Banks (short list; the user extends it in settings).
        "com.nubank.mobile", "br.com.itau.itauapp", "com.tinkoff.TinkoffBank", "ru.sberbankruapp",
    ]

    public static func isExcluded(bundleID: String?, exclusions: Set<String>) -> Bool {
        guard let bundleID else { return false }
        return exclusions.contains(bundleID)
    }

    /// Last `limit` characters (grapheme clusters, so emoji and combining marks are never cut) of the text
    /// before the caret. `caretUTF16` is an Accessibility offset (UTF-16 units); it is clamped to the text and,
    /// if it lands inside a surrogate pair, moved back to the previous character boundary.
    public static func textBeforeCaret(_ value: String, caretUTF16: Int, limit: Int = maxTextBeforeCursor) -> String {
        let utf16 = value.utf16
        let caret = max(0, min(caretUTF16, utf16.count))
        var end = utf16.index(utf16.startIndex, offsetBy: caret)
        // Snap back to a Character boundary (out of a surrogate pair or an emoji sequence).
        while end > utf16.startIndex, end.samePosition(in: value) == nil { end = utf16.index(before: end) }
        let head = value[..<(end.samePosition(in: value) ?? value.startIndex)]
        return trimToTail(String(head), limit: limit)
    }

    /// Keep the last `limit` characters of `s`.
    public static func trimToTail(_ s: String, limit: Int = maxTextBeforeCursor) -> String {
        guard s.count > limit else { return s }
        return String(s.suffix(limit))
    }

    /// Repair for text fetched by UTF-16 range starting mid-document: a leading lone surrogate becomes U+FFFD
    /// after decoding; drop it, then trim to the tail.
    public static func trimFetchedTail(_ s: String, limit: Int = maxTextBeforeCursor) -> String {
        var t = Substring(s)
        while t.first == "\u{FFFD}" { t = t.dropFirst() }
        return trimToTail(String(t), limit: limit)
    }

    /// Browser address for style matching: no scheme, no credentials, no query or fragment; host and path kept.
    /// `https://Mail.Google.com/mail/u/0/?x=1#inbox` -> `mail.google.com/mail/u/0/`. Returns nil for blank
    /// input and for non-web addresses (about:, chrome://, file://, ...).
    public static func normalizeURL(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let r = s.range(of: "://") {
            let scheme = s[..<r.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            s = String(s[r.upperBound...])
        } else if let colon = s.firstIndex(of: ":") {
            // No "//": "host:3000/x" is a web address, "about:blank" / "mailto:x" are not.
            let stop = s.firstIndex(of: "/") ?? s.endIndex
            if colon < stop {
                let port = s[s.index(after: colon)..<stop]
                if port.isEmpty || !port.allSatisfy(\.isNumber) { return nil }
            }
        }
        if let i = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<i]) }
        if let at = s.firstIndex(of: "@"), at < (s.firstIndex(of: "/") ?? s.endIndex) {
            s = String(s[s.index(after: at)...])
        }
        guard !s.isEmpty else { return nil }
        return s.lowercased() == s ? s : lowercaseHost(s)
    }

    private static func lowercaseHost(_ s: String) -> String {
        guard let slash = s.firstIndex(of: "/") else { return s.lowercased() }
        return s[..<slash].lowercased() + s[slash...]
    }

    /// Same field check before insertion (spec 3.6 step 1): same pid and same element id.
    /// If either element id is unknown, only the pid is compared.
    public static func isSameTarget(_ a: ContextSnapshot, _ b: ContextSnapshot) -> Bool {
        guard a.pid == b.pid else { return false }
        guard let x = a.focusedElementID, let y = b.focusedElementID else { return true }
        return x == y
    }
}
