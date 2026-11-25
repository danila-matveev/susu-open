// Text helpers for the History screen: strings from History.xcstrings, times, days, hotkey glyphs, highlighting.
import SwiftUI
import SusuCore

/// `Text` from the History string table (follows the `\.locale` environment).
func HText(_ key: LocalizedStringKey) -> Text { Text(key, tableName: "History", bundle: .module) }

enum HL {
    /// String from History.xcstrings for an interface language.
    static func string(_ key: String, _ language: InterfaceLanguage, _ args: CVarArg...) -> String {
        let raw = L10n.bundle(for: language).localizedString(forKey: key, value: key, table: "History")
        return args.isEmpty ? raw : String(format: raw, locale: nil, arguments: args)
    }

    static func isRussian(_ language: InterfaceLanguage) -> Bool {
        switch language {
        case .ru: true
        case .en: false
        case .system: Locale.current.language.languageCode?.identifier == "ru"
        }
    }

    /// «40 записей за 3 дня».
    static func summary(_ s: HistorySummary, _ language: InterfaceLanguage) -> String {
        let ru = isRussian(language)
        func form(_ n: Int, _ noun: String) -> String {
            let cat: String
            if ru {
                let m10 = n % 10, m100 = n % 100
                cat = m10 == 1 && m100 != 11 ? "one" : (2...4 ~= m10 && !(12...14 ~= m100) ? "few" : "many")
            } else {
                cat = n == 1 ? "one" : "many"
            }
            return "\(n.formatted(.number.locale(Locale(identifier: ru ? "ru" : "en")))) " + string("hist.\(noun).\(cat)", language)
        }
        return string("hist.summary", language, form(s.count, "rec"), form(s.days, "day"))
    }

    // MARK: time

    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func locale(_ language: InterfaceLanguage) -> Locale { L10n.locale(for: language) }

    /// «Сегодня, 12 ноября» / «Вчера, 11 ноября» / «10 ноября, вторник» (+ year when it is not this year).
    static func dayTitle(_ day: Date, now: Date = AppClock.now, calendar: Calendar = .current, _ language: InterfaceLanguage) -> String {
        let f = DateFormatter()
        f.locale = locale(language)
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        let today = calendar.startOfDay(for: now)
        f.setLocalizedDateFormatFromTemplate(sameYear ? "dMMMM" : "dMMMMyyyy")
        let date = f.string(from: day)
        if day == today { return string("hist.today", language) + ", " + date }
        if day == calendar.date(byAdding: .day, value: -1, to: today) { return string("hist.yesterday", language) + ", " + date }
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return date + ", " + f.string(from: day)
    }

    /// Short «Сегодня, 14:44» used in the record card.
    static func dayShort(_ date: Date, now: Date = AppClock.now, calendar: Calendar = .current, _ language: InterfaceLanguage) -> String {
        let day = calendar.startOfDay(for: date), today = calendar.startOfDay(for: now)
        let t = time(date, calendar: calendar)
        if day == today { return string("hist.today", language) + ", " + t }
        if day == calendar.date(byAdding: .day, value: -1, to: today) { return string("hist.yesterday", language) + ", " + t }
        let f = DateFormatter()
        f.locale = locale(language)
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f.string(from: day) + ", " + t
    }

    static func greeting(hour: Int, name: String, _ language: InterfaceLanguage) -> String {
        let key = switch hour {
        case 5..<12: "hist.greet.morning"
        case 12..<18: "hist.greet.day"
        case 18..<23: "hist.greet.evening"
        default: "hist.greet.night"
        }
        let base = string(key, language)
        return name.isEmpty ? base : base + ", " + name
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func cost(_ usd: Double?) -> String {
        guard let usd else { return "—" }
        return usd < 0.01 ? String(format: "$%.4f", usd) : String(format: "$%.2f", usd)
    }

    // MARK: hotkey

    static func hotkey(_ k: HotkeySetting, _ language: InterfaceLanguage) -> String {
        func glyph(_ m: HotkeyModifier) -> String {
            switch m { case .control: "⌃"; case .option: "⌥"; case .command: "⌘"; case .shift: "⇧" }
        }
        if let m = k.modifierKey {
            let (g, right): (String, Bool) = switch m {
            case .leftControl: ("⌃", false); case .rightControl: ("⌃", true)
            case .leftOption: ("⌥", false); case .rightOption: ("⌥", true)
            case .leftCommand: ("⌘", false); case .rightCommand: ("⌘", true)
            case .leftShift: ("⇧", false); case .rightShift: ("⇧", true)
            case .fn: ("fn", false)
            }
            return right ? string("hist.key.right", language, g) : g
        }
        let order: [HotkeyModifier] = [.control, .option, .shift, .command]
        let mods = order.filter(k.modifiers.contains).map(glyph).joined()
        return mods + (k.keyCode.map(keyName) ?? "")
    }

    private static func keyName(_ code: Int) -> String {
        let names: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
            13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J",
            40: "K", 45: "N", 46: "M", 36: "↩", 48: "⇥", 49: "Space", 53: "Esc",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
            109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
            79: "F18", 80: "F19", 90: "F20",
        ]
        return names[code] ?? "#\(code)"
    }
}

extension Dictation {
    /// What the user got: edits win over the cleaned text, which wins over the raw text.
    var displayText: String {
        for t in [editedText, finalText, rawText] {
            if let t, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
        }
        return ""
    }
    var hasText: Bool { !displayText.isEmpty }
    var appLabel: String { appName ?? bundleId ?? "—" }
    var needsAttention: Bool { status == .notInserted || status == .failed || status == .cancelled }
}

enum Highlight {
    /// `text` with the words that start with a query term marked (same rule as the FTS prefix search).
    static func attributed(_ text: String, query: String) -> AttributedString {
        var out = AttributedString(text)
        let terms = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !terms.isEmpty else { return out }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        for term in terms {
            var from = text.startIndex
            while from < text.endIndex, let r = text.range(of: term, options: opts, range: from..<text.endIndex) {
                let atWordStart = r.lowerBound == text.startIndex
                    || !(text[text.index(before: r.lowerBound)].isLetter || text[text.index(before: r.lowerBound)].isNumber)
                if atWordStart, let lo = AttributedString.Index(r.lowerBound, within: out),
                   let hi = AttributedString.Index(r.upperBound, within: out) {
                    out[lo..<hi].backgroundColor = Palette.accentSoft
                }
                from = r.upperBound
            }
        }
        return out
    }
}
