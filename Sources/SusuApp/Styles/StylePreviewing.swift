// «Как будет после стиля»: the preview calls a hook so the editor pipeline can plug in later.
import SwiftUI
import SusuCore

public struct StylePreviewResult: Sendable, Equatable {
    public var text: String
    /// false when only the deterministic rules ran (no editor model).
    public var usedEditor: Bool
    /// Shown in the meta line, e.g. "Groq".
    public var editorLabel: String?
    /// A spoken «отправь» ended the phrase.
    public var pressEnter: Bool

    public init(text: String, usedEditor: Bool, editorLabel: String? = nil, pressEnter: Bool = false) {
        self.text = text; self.usedEditor = usedEditor; self.editorLabel = editorLabel; self.pressEnter = pressEnter
    }
}

public enum StylePreviewError: Error, Sendable {
    /// The editor needs an API key that is not set; the screen offers «Добавить ключ».
    case noEditorKey
}

/// Runs raw text through a style. The editor pipeline provides the real one; the screen falls back to
/// `StylePreview.rulesOnly` while the hook is nil.
public typealias StylePreviewing = @Sendable (_ raw: String, _ style: Style) async throws -> StylePreviewResult

private struct StylePreviewingKey: EnvironmentKey { static let defaultValue: StylePreviewing? = nil }

extension EnvironmentValues {
    public var stylePreviewing: StylePreviewing? {
        get { self[StylePreviewingKey.self] }
        set { self[StylePreviewingKey.self] = newValue }
    }
}

public enum StylePreview {
    /// Step 1 of cleanup only (spec 3.4): rules plus the user's replacements and snippets.
    public static func rulesOnly(raw: String, style: Style, dictionary: DictionaryService) async throws -> StylePreviewResult {
        let replacements = try await dictionary.list(kind: DictionaryService.Kind.replacement).compactMap(RulesEntry.init)
        let snippets = try await dictionary.list(kind: DictionaryService.Kind.snippet).compactMap(RulesEntry.init)
        let options = RulesOptions(replacements: replacements, snippets: snippets,
                                   capitalize: style.level != .verbatim, voiceCommandsEnabled: style.voiceCommands)
        let result = CleanupRules.apply(raw, options: options)
        return StylePreviewResult(text: result.text, usedEditor: false, pressEnter: result.pressEnter)
    }
}
