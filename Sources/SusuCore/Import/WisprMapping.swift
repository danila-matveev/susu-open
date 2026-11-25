import Foundation

/// Pure mapping rules from spec 6 (no database access, easy to test).
enum WisprMapping {
    /// Inserted text: `pastedText` -> `formattedText` -> `asrText`.
    static func finalText(pasted: String?, formatted: String?, asr: String?) -> String? {
        pasted ?? formatted ?? asr
    }

    /// `ptt` -> hold, `popo` -> handsfree, `command` -> agent request (no mode).
    static func kindAndMode(command: String?) -> (DictationKind, DictationMode?) {
        switch command {
        case "ptt": return (.dictation, .hold)
        case "popo": return (.dictation, .handsfree)
        case "command": return (.agent, nil)
        default: return (.dictation, nil)
        }
    }

    static func status(wisprStatus: String?, archived: Bool) -> DictationStatus {
        if wisprStatus == "error" { return .failed }
        if archived { return .archived }
        return .imported
    }

    /// Wispr's `e2eLatency` is milliseconds, but some rows hold clock values: anything over 10 minutes is noise.
    static func latencyMs(_ v: Double?) -> Int? {
        guard let v, v >= 0, v <= 600_000 else { return nil }
        return Int(v.rounded())
    }

    static func durationMs(seconds: Double?) -> Int? {
        guard let s = seconds, s >= 0, s < 86_400 else { return nil }
        return Int((s * 1000).rounded())
    }

    static func dictionaryKind(isSnippet: Bool, replacement: String?) -> String {
        if isSnippet { return "snippet" }
        return replacement == nil ? "word" : "replacement"
    }

    // MARK: Styles (И5)

    static let styleCode = "Код", styleMessengers = "Мессенджеры", styleMail = "Почта", styleOther = "Прочее"

    private static let codeAppMarkers = ["vscode", "cursor", "terminal", "iterm", "ghostty", "warp", "xcode",
                                         "claude", "codex", "zed", "jetbrains", "sublime", "nova"]

    static func isCodeApp(_ bundleId: String) -> Bool {
        let l = bundleId.lowercased()
        return codeAppMarkers.contains { l.contains($0) }
    }

    /// Wispr group of an app (`personalizationAppType`) -> name of the default Susu style. `unset` gives nil.
    static func styleName(group: String, bundleId: String) -> String? {
        switch group {
        case "work": return isCodeApp(bundleId) ? styleCode : styleMessengers
        case "email": return styleMail
        case "personal": return styleMessengers
        case "other": return styleOther
        default: return nil
        }
    }

    /// The group an app was seen in most often; ties go to the alphabetically first group.
    static func dominantGroup(_ counts: [String: Int]) -> String? {
        counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
    }
}
