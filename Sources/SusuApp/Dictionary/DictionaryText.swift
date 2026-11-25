// Strings of the dictionary and snippet screens live in their own table, `Dictionary.xcstrings`.
import SwiftUI
import SusuCore

enum DL {
    static let table = "Dictionary"

    static func string(_ key: String, _ language: InterfaceLanguage) -> String {
        L10n.bundle(for: language).localizedString(forKey: key, value: nil, table: table)
    }

    static func format(_ key: String, _ language: InterfaceLanguage, _ args: CVarArg...) -> String {
        String(format: string(key, language), locale: L10n.locale(for: language), arguments: args)
    }

    static func isRussian(_ language: InterfaceLanguage) -> Bool {
        switch language {
        case .ru: true
        case .en: false
        case .system: Locale.preferredLanguages.first?.hasPrefix("ru") == true
        }
    }

    /// Picks a form from "one|few|many" (RU) or "one|other" (EN) stored in one string.
    static func plural(_ key: String, _ n: Int, _ language: InterfaceLanguage) -> String {
        let forms = string(key, language).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard forms.count > 1 else { return forms.first ?? key }
        if isRussian(language), forms.count >= 3 {
            let m = n % 10, h = n % 100
            return forms[(m == 1 && h != 11) ? 0 : (m >= 2 && m <= 4 && (h < 12 || h > 14)) ? 1 : 2]
        }
        return forms[n == 1 ? 0 : 1]
    }

    /// "12 раз" / "1 time"
    static func uses(_ n: Int, _ language: InterfaceLanguage) -> String {
        String(format: plural("common.uses", n, language), locale: L10n.locale(for: language), n)
    }
}

/// A `Text` from the Dictionary table.
func dt(_ key: LocalizedStringKey) -> Text { Text(key, tableName: DL.table, bundle: .module) }

/// Case- and ё-insensitive form used to compare phrases (same idea as the core's word compare).
func normalizedPhrase(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "ё", with: "е")
}
