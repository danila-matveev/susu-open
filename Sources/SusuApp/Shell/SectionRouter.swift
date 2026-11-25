// THE plug-in point: one switch per window maps a section to its screen.
// To add a real screen, replace the `SectionPlaceholder` line of your case with your view.
// A screen draws its own `ScreenHeader` and content inside the white card the shell gives it.
import SwiftUI

@MainActor
public enum SectionRouter {
    /// Real history hooks, set by AppDelegate once services exist.
    @MainActor public static var historyActions = HistoryActions.none
    @MainActor public static var stylePreviewing: StylePreviewing?

    @MainActor @ViewBuilder
    public static func view(for section: MainSection) -> some View {
        switch section {
        case .history: HistoryScreen().environment(\.historyActions, historyActions)
        case .calls: SectionPlaceholder(title: section.title, symbol: section.symbol)
        case .notes: NotesScreen()
        case .dictionary: DictionaryScreen()
        case .snippets: SnippetsScreen()
        case .styles: StylesScreen().environment(\.stylePreviewing, stylePreviewing)
        case .skills: SectionPlaceholder(title: section.title, symbol: section.symbol)
        case .stats: StatsScreen()
        }
    }

    @ViewBuilder
    public static func view(for section: SettingsSection) -> some View {
        switch section {
        case .keys: KeysSettingsView()
        case .mic: MicSettingsView()
        case .lang: LanguageSettingsView()
        case .models: ModelsSettingsView()
        case .calls: CallsSettingsView()
        case .agent: AgentSettingsView()
        case .account: AccountSettingsView()
        case .data: DataPrivacySettingsView()
        case .misc: MiscSettingsView()
        }
    }
}

/// Title plus an empty state. Stand-in until a section gets its screen.
struct SectionPlaceholder: View {
    let title: LocalizedStringKey
    let symbol: String
    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title)
            EmptyState(symbol: symbol, text: "shell.comingSoon")
        }
    }
}
