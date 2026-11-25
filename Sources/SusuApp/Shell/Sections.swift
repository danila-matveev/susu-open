// Section lists of the two windows. Titles are String Catalog keys.
import SwiftUI

public enum MainSection: String, CaseIterable, Identifiable, Sendable {
    case history, calls, notes, dictionary, snippets, styles, skills, stats
    public var id: String { rawValue }

    public var title: LocalizedStringKey {
        switch self {
        case .history: "nav.home"
        case .calls: "nav.calls"
        case .notes: "nav.notes"
        case .dictionary: "nav.dictionary"
        case .snippets: "nav.snippets"
        case .styles: "nav.styles"
        case .skills: "nav.skills"
        case .stats: "nav.stats"
        }
    }

    public var symbol: String {
        switch self {
        case .history: "house"
        case .calls: "video"
        case .notes: "note.text"
        case .dictionary: "character.book.closed"
        case .snippets: "chevron.left.forwardslash.chevron.right"
        case .styles: "textformat"
        case .skills: "sparkles"
        case .stats: "chart.bar"
        }
    }
}

public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case keys, mic, lang, models, calls, agent, account, data, misc
    public var id: String { rawValue }

    public var title: LocalizedStringKey {
        switch self {
        case .keys: "set.keys"
        case .mic: "set.mic"
        case .lang: "set.lang"
        case .models: "set.models"
        case .calls: "set.calls"
        case .agent: "set.agent"
        case .account: "set.account"
        case .data: "set.data"
        case .misc: "set.misc"
        }
    }

    public var symbol: String {
        switch self {
        case .keys: "keyboard"
        case .mic: "mic"
        case .lang: "globe"
        case .models: "cpu"
        case .calls: "video"
        case .agent: "sparkles"
        case .account: "person.crop.circle"
        case .data: "lock.shield"
        case .misc: "slider.horizontal.3"
        }
    }

    /// Nav groups in the settings window.
    public static var groups: [(title: LocalizedStringKey, items: [SettingsSection])] {
        [
            ("set.group.app", [.keys, .mic, .lang, .models, .calls, .agent]),
            ("set.group.account", [.account, .data, .misc]),
        ]
    }
}
