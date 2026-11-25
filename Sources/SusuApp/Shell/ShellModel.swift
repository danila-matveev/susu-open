// Shared state of the window shell: current sections, theme, interface language.
// Theme and language come from `SettingsStore` and apply on the fly (no restart).
import SwiftUI
import SusuCore

@MainActor
public final class ShellModel: ObservableObject {
    public let services: AppServices
    public var store: SettingsStore { services.settings }
    @Published public var mainSection: MainSection = .history
    @Published public var settingsSection: SettingsSection = .keys
    @Published public private(set) var theme: AppTheme
    @Published public private(set) var language: InterfaceLanguage

    /// Set by `ShellController`; screens call these to open windows.
    public var openSettings: (SettingsSection?) -> Void = { _ in }
    public var openMain: (MainSection?) -> Void = { _ in }

    public init(services: AppServices) {
        self.services = services
        let store = services.settings
        let s = store.current
        theme = s.theme
        language = s.interfaceLanguage
        Task { [weak self] in
            for await s in store.changes() {
                guard let self else { return }
                self.apply(s)
            }
        }
    }

    private func apply(_ s: SusuCore.Settings) {
        if theme != s.theme { theme = s.theme }
        if language != s.interfaceLanguage { language = s.interfaceLanguage }
    }

    var locale: Locale { L10n.locale(for: language) }

    /// nil means "follow the system".
    var colorScheme: ColorScheme? {
        switch theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension View {
    /// Root of every Susu window: injects the model and applies theme and locale.
    func shellRoot(_ model: ShellModel) -> some View {
        modifier(ShellRootModifier(model: model))
    }
}

private struct ShellRootModifier: ViewModifier {
    @ObservedObject var model: ShellModel
    func body(content: Content) -> some View {
        content
            .environmentObject(model)
            .environment(\.locale, model.locale)
            .preferredColorScheme(model.colorScheme)
    }
}
