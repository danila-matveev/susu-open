// Hooks the History screen calls for things that need the audio pipeline or the editor.
// The orchestrator injects real implementations with `.environment(\.historyActions, ...)`.
// The default does nothing and answers `.unavailable`, so the screen is fully usable without it.
import SwiftUI
import SusuCore

public enum HistoryActionResult: Sendable, Equatable {
    /// Done. The optional text is shown as a toast.
    case done(String? = nil)
    case unavailable
}

/// What to recompute in the compare view: another editing model and/or another style.
public struct CompareChoice: Sendable, Equatable {
    public var modelID: String?
    public var styleID: String?
    public init(modelID: String? = nil, styleID: String? = nil) { self.modelID = modelID; self.styleID = styleID }
}

public struct CompareOption: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var isCurrent: Bool
    public var hasKey: Bool
    public init(id: String, title: String, isCurrent: Bool = false, hasKey: Bool = true) {
        self.id = id; self.title = title; self.isCurrent = isCurrent; self.hasKey = hasKey
    }
}

public struct CompareOptions: Sendable, Equatable {
    public var models: [CompareOption]
    public var styles: [CompareOption]
    public init(models: [CompareOption], styles: [CompareOption]) { self.models = models; self.styles = styles }
}

/// `compare` throws this when the second model has no API key.
public struct CompareNoKeyError: Error, Sendable {
    public var model: String
    public init(model: String) { self.model = model }
}

public struct HistoryActions: Sendable {
    /// «Повторить»: insert the text again (not inserted) or recognize the saved audio again (failed / cancelled).
    public var retry: @MainActor @Sendable (Dictation) async -> HistoryActionResult
    /// «Переделать»: run the same text through the editor again.
    public var redo: @MainActor @Sendable (Dictation) async -> HistoryActionResult
    /// Called after the text was copied for «Вставить снова». A real implementation may paste it.
    public var pasteAgain: @MainActor @Sendable (Dictation) -> Void
    /// «Отменить» on an agent row. `canUndoAgent` decides whether the button is shown.
    public var undoAgent: @MainActor @Sendable (Dictation) async -> HistoryActionResult
    public var canUndoAgent: @MainActor @Sendable (Dictation) -> Bool
    /// «Импортировать из Wispr».
    public var importFromWispr: @MainActor @Sendable () -> Void
    /// True when Wispr Flow's database exists (decides whether the import button is shown on the empty screen).
    public var wisprFound: Bool
    /// Models and styles offered in the compare view. nil = built-in list from the provider registry and styles.
    public var compareOptions: (@MainActor @Sendable (Dictation) -> CompareOptions?)?
    /// Recomputes the final text with another model / style. Throws `CompareNoKeyError` when there is no key.
    public var compare: @MainActor @Sendable (Dictation, CompareChoice) async throws -> String

    public init(
        retry: @escaping @MainActor @Sendable (Dictation) async -> HistoryActionResult = { _ in .unavailable },
        redo: @escaping @MainActor @Sendable (Dictation) async -> HistoryActionResult = { _ in .unavailable },
        pasteAgain: @escaping @MainActor @Sendable (Dictation) -> Void = { _ in },
        undoAgent: @escaping @MainActor @Sendable (Dictation) async -> HistoryActionResult = { _ in .unavailable },
        canUndoAgent: @escaping @MainActor @Sendable (Dictation) -> Bool = { _ in false },
        importFromWispr: @escaping @MainActor @Sendable () -> Void = {},
        wisprFound: Bool = HistoryActions.wisprDatabaseExists,
        compareOptions: (@MainActor @Sendable (Dictation) -> CompareOptions?)? = nil,
        compare: @escaping @MainActor @Sendable (Dictation, CompareChoice) async throws -> String = { _, _ in
            throw CompareNoKeyError(model: "")
        }
    ) {
        self.retry = retry; self.redo = redo; self.pasteAgain = pasteAgain; self.undoAgent = undoAgent
        self.canUndoAgent = canUndoAgent; self.importFromWispr = importFromWispr; self.wisprFound = wisprFound
        self.compareOptions = compareOptions; self.compare = compare
    }

    /// Everything unavailable.
    public static let none = HistoryActions()

    /// ~/Library/Application Support/Wispr Flow/flow.sqlite exists.
    public static var wisprDatabaseExists: Bool {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }
        return FileManager.default.fileExists(
            atPath: base.appendingPathComponent("Wispr Flow/flow.sqlite").path)
    }
}

private struct HistoryActionsKey: EnvironmentKey {
    static let defaultValue = HistoryActions.none
}

extension EnvironmentValues {
    public var historyActions: HistoryActions {
        get { self[HistoryActionsKey.self] }
        set { self[HistoryActionsKey.self] = newValue }
    }
}
