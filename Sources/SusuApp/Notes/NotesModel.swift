// State of the Notes screen: the list (observed from the database), search, tag filter, selection, edits, undo.
import AppKit
import SwiftUI
import SusuCore

@MainActor
final class NotesModel: ObservableObject {
    struct Toast: Equatable { var text: String; var undoID: String? }

    let store: NotesStore
    @Published private(set) var all: [Note] = []
    @Published private(set) var visible: [Note] = []
    @Published private(set) var loaded = false
    @Published var query = "" { didSet { if query != oldValue { Task { await refresh() } } } }
    @Published var tagFilter: String? { didSet { if tagFilter != oldValue { Task { await refresh() } } } }
    @Published var selectedID: String?
    @Published var toast: Toast?

    private var pending: (id: String, title: String, text: String, tags: [String])?
    private var saveTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    init(services: AppServices) {
        store = NotesStore(database: services.database, baseDirectory: services.dataDirectory)
    }

    /// Tags in use, most used first.
    var tags: [String] {
        var counts: [String: Int] = [:]
        for n in all { for t in n.tags { counts[t, default: 0] += 1 } }
        return counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map(\.key)
    }

    var selected: Note? { visible.first { $0.id == selectedID } }

    // MARK: Load

    func observe() async {
        do {
            for try await list in store.observeNotes() {
                all = list
                if tagFilter != nil, !tags.contains(tagFilter!) { tagFilter = nil }
                await refresh()
                if !loaded { loaded = true; if selectedID == nil { selectedID = visible.first?.id } }
            }
        } catch {}
    }

    func refresh() async {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            visible = tagFilter.map { t in all.filter { $0.tags.contains(t) } } ?? all
        } else {
            visible = (try? await store.search(query, tag: tagFilter)) ?? []
        }
    }

    // MARK: Actions

    func newNote() async {
        await flush()
        dropBlankSelection()
        query = ""; tagFilter = nil
        if let n = try? await store.create(text: "", origin: "manual") {
            all.insert(n, at: 0)
            await refresh()
            selectedID = n.id
        }
    }

    func select(_ id: String) async {
        guard id != selectedID else { return }
        await flush()
        dropBlankSelection()
        selectedID = id
    }

    /// An untouched «new note» that the user leaves is thrown away.
    private func dropBlankSelection() {
        guard let n = selected, n.origin == "manual", (n.title ?? "").isEmpty, (n.text ?? "").isEmpty else { return }
        Task { try? await store.softDelete(id: n.id) }
    }

    func edit(id: String, title: String, text: String, tags: [String]) {
        pending = (id, title, text, tags)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    func flush() async {
        saveTask?.cancel()
        guard let p = pending else { return }
        pending = nil
        _ = try? await store.update(id: p.id) { n in
            n.title = p.title.isEmpty ? nil : p.title
            n.text = p.text
            n.tags = p.tags
        }
    }

    func delete(_ id: String, text: String) async {
        pending = nil; saveTask?.cancel()
        let index = visible.firstIndex { $0.id == id } ?? 0
        try? await store.softDelete(id: id)
        all.removeAll { $0.id == id }
        await refresh()
        selectedID = visible.isEmpty ? nil : visible[min(index, visible.count - 1)].id
        show(Toast(text: text, undoID: id), seconds: 5)
    }

    func undo(_ id: String) async {
        try? await store.restore(id: id)
        toast = nil
        if let n = try? await store.fetch(id: id) {
            all = ([n] + all).sorted { $0.createdAt > $1.createdAt }
            await refresh()
            selectedID = id
        }
    }

    func show(_ t: Toast, seconds: Double = 2) {
        toast = t
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func copyText(_ note: Note, toast text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text ?? "", forType: .string)
        show(Toast(text: text))
    }

    /// Copies the audio file to ~/Downloads.
    func downloadAudio(_ note: Note, toast text: String) {
        guard let src = store.audioURL(for: note),
              let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        var dest = dir.appendingPathComponent(src.lastPathComponent)
        var i = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(src.deletingPathExtension().lastPathComponent) \(i).\(src.pathExtension)"); i += 1
        }
        if (try? FileManager.default.copyItem(at: src, to: dest)) != nil { show(Toast(text: text)) }
    }
}
