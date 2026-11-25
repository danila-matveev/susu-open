// T2.7: watch the field for 60 s after an insert; if the user fixed words, save edited_text and learn them.
import AppKit
import SusuCore

@MainActor
enum EditWatcher {
    /// Called with added entries so the app can show «Запомнил · Отменить».
    static func watch(id: String, inserted: String, services s: AppServices, onLearned: @escaping @MainActor ([DictionaryEntry]) -> Void) {
        // The paste lands asynchronously; read the field a moment later.
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard let start = ContextSnapshotter.focusedValue(), start.value.contains(inserted) else { return }
            var last = start.value
            // ponytail: 2 s polling for 60 s; AXObserver value-changed notifications if this ever costs anything.
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(2))
                guard let now = ContextSnapshotter.focusedValue(), now.id == start.id else { break }
                last = now.value
            }
            guard let edited = EditSpan.edited(inserted: inserted, field: start.value, later: last),
                  edited.trimmingCharacters(in: .whitespacesAndNewlines) != inserted.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return }
            _ = try? await s.history.update(id: id) { $0.editedText = edited }
            let known = (try? await s.dictionary.knownPhrases()) ?? []
            let candidates = EditLearner.candidates(inserted: inserted, edited: edited, known: known)
            guard !candidates.isEmpty else { return }
            let choice = s.settings.current.providers.editor ?? DictationService.defaultEditor
            let chat = SpendRecordingChat(DictationService.editorChat(choice, secrets: s.secrets, registry: s.registry),
                                          provider: choice.providerID, log: s.spend)
            guard let judged = try? await EditLearner.judge(candidates, llm: chat, model: choice.model),
                  let added = try? await EditLearner.apply(judged, to: s.dictionary), !added.isEmpty else { return }
            onLearned(added)
        }
    }

    /// Toast text: «Анастасия» or «насти → Анастасии».
    static func fact(_ entries: [DictionaryEntry]) -> String {
        entries.map { e in e.replacement.map { "\(e.phrase) → \($0)" } ?? e.phrase }.joined(separator: ", ")
    }
}
