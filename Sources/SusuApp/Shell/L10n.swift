// Localization helpers. SwiftUI `Text("key", bundle: .module)` follows `\.locale` from the environment;
// AppKit strings (menu titles, window titles) have no environment, so they go through `L10n.string`.
import Foundation
import SusuCore

public enum L10n {
    /// Locale for SwiftUI's `\.locale` environment value.
    public static func locale(for language: InterfaceLanguage) -> Locale {
        switch language {
        case .system: .autoupdatingCurrent
        case .ru: Locale(identifier: "ru")
        case .en: Locale(identifier: "en")
        }
    }

    /// The `.lproj` bundle for a fixed language; `.module` itself for "system" (the OS picks).
    static func bundle(for language: InterfaceLanguage) -> Bundle {
        switch language {
        case .system: return .module
        case .ru, .en:
            if let path = Bundle.module.path(forResource: language.rawValue, ofType: "lproj"),
               let b = Bundle(path: path) { return b }
            return .module
        }
    }

    /// Looks a key up in the String Catalog for the given interface language.
    public static func string(_ key: String, language: InterfaceLanguage) -> String {
        bundle(for: language).localizedString(forKey: key, value: nil, table: nil)
    }
}
