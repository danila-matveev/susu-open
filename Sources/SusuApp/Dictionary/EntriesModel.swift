// State of the Dictionary and Snippets lists: loads entries, saves, deletes with «Отменить», toasts.
import SwiftUI
import SusuCore

@MainActor
final class EntriesModel: ObservableObject {
    enum Scope { case dictionary, snippets }

    let scope: Scope
    let service: DictionaryService
    @Published private(set) var entries: [DictionaryEntry] = []
    @Published private(set) var loaded = false
    /// Rows to flash after being added.
    @Published private(set) var fresh: Set<String> = []
    @Published private(set) var toast: ToastData?
    @Published var failure: String?
    private var toastTask: Task<Void, Never>?

    init(scope: Scope, service: DictionaryService) {
        self.scope = scope; self.service = service
    }

    private func inScope(_ e: DictionaryEntry) -> Bool {
        (e.kind == DictionaryService.Kind.snippet) == (scope == .snippets)
    }

    func reload() async {
        do {
            entries = try await service.list().filter(inScope)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        loaded = true
    }

    /// True when another live entry of this screen already has the phrase (case-insensitive).
    func isDuplicate(phrase: String, excluding id: String?) -> Bool {
        let key = normalizedPhrase(phrase)
        guard !key.isEmpty else { return false }
        return entries.contains { $0.id != id && normalizedPhrase($0.phrase) == key }
    }

    /// Adds (`id == nil`) or updates an entry. `replacement` is the right text (dictionary) or the snippet text.
    @discardableResult
    func save(id: String?, phrase: String, replacement: String) async -> DictionaryEntry? {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = scope == .snippets ? DictionaryService.Kind.snippet
            : (replacement.isEmpty ? DictionaryService.Kind.word : DictionaryService.Kind.replacement)
        do {
            let saved: DictionaryEntry?
            if let id {
                saved = try await service.update(id: id) { e in
                    e.phrase = phrase; e.replacement = replacement.isEmpty ? nil : replacement; e.kind = kind
                }
            } else {
                saved = try await service.add(kind: kind, phrase: phrase, replacement: replacement.isEmpty ? nil : replacement)
                if let saved { flash([saved.id]) }
            }
            await reload()
            return saved
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }

    func toggleStar(_ entry: DictionaryEntry) async {
        try? await service.setStarred(id: entry.id, !entry.starred)
        await reload()
    }

    /// Soft delete; the toast offers «Отменить» for 5 s.
    func delete(_ entry: DictionaryEntry, language: InterfaceLanguage) async {
        do { try await service.softDelete(id: entry.id) } catch { failure = error.localizedDescription; return }
        await reload()
        let id = entry.id
        let snippet = scope == .snippets
        show(ToastData(symbol: "trash", title: DL.string(snippet ? "snip.deleted" : "dict.deleted", language),
                       detail: snippet ? "«\(entry.phrase)»" : entry.phrase,
                       actionTitle: DL.string("common.undo", language),
                       action: { [weak self] in Task { await self?.undoDelete(id: id) } },
                       duration: 5))
    }

    private func undoDelete(id: String) async {
        _ = try? await service.restore(id: id)
        await reload()
    }

    func flash(_ ids: [String]) {
        fresh.formUnion(ids)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            self?.fresh.subtract(ids)
        }
    }

    func show(_ data: ToastData) {
        toastTask?.cancel()
        toast = data
        let id = data.id
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(data.duration))
            guard !Task.isCancelled, self?.toast?.id == id else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    func runToastAction() {
        let action = toast?.action
        dismissToast()
        action?()
    }
}
