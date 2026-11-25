import Foundation
import Testing
@testable import SusuCore

@Suite struct NotesStoreTests {
    func makeStore(dir: URL? = nil) throws -> NotesStore {
        NotesStore(database: try SusuDatabase.inMemory(), baseDirectory: dir)
    }
    static func date(_ s: String) -> Date { SusuTime.date(s)! }

    @Test func createUpdateAndTagsRoundTrip() async throws {
        let store = try makeStore()
        let n = try await store.create(title: "Идея", text: "Сделать коробку", tags: ["упаковка", "идеи"], origin: "hotkey")
        let got = try #require(try await store.fetch(id: n.id))
        #expect(got.title == "Идея" && got.tags == ["упаковка", "идеи"] && got.origin == "hotkey")
        let upd = try await store.update(id: n.id) { $0.text = "Новый текст"; $0.tags = [] }
        #expect(upd?.text == "Новый текст" && upd?.tags == [] && upd?.tagsJson == nil)
        #expect(try await store.update(id: "nope") { _ in } == nil)
    }

    @Test func listNewestFirstAndSoftDeleteWithUndo() async throws {
        let store = try makeStore()
        let a = try await store.create(title: "a", now: Self.date("2026-05-01T10:00:00Z"))
        let b = try await store.create(title: "b", now: Self.date("2026-05-02T10:00:00Z"))
        let c = try await store.create(title: "c", now: Self.date("2026-05-03T10:00:00Z"))
        #expect(try await store.list().map(\.id) == [c.id, b.id, a.id])
        try await store.softDelete(id: b.id)
        #expect(try await store.list().map(\.id) == [c.id, a.id])
        #expect(try await store.fetch(id: b.id) == nil)
        #expect(try await store.update(id: b.id) { $0.title = "x" } == nil)
        try await store.restore(id: b.id)
        #expect(try await store.list().map(\.id) == [c.id, b.id, a.id])
    }

    @Test func searchTitleAndTextWithPrefixes() async throws {
        let store = try makeStore()
        let a = try await store.create(title: "Вопросы Игорю", text: "про образцы тканей")
        _ = try await store.create(title: "Упаковка", text: "печать на коробке")
        #expect(try await store.search("игор").map(\.id) == [a.id])
        #expect(try await store.search("образц тк").map(\.id) == [a.id])
        #expect(try await store.search("%%%").isEmpty)
        // an edit shows up in the index
        try await store.update(id: a.id) { $0.text = "про пошив" }
        #expect(try await store.search("образцы").isEmpty)
        #expect(try await store.search("пошив").map(\.id) == [a.id])
        // deleted notes are not found
        try await store.softDelete(id: a.id)
        #expect(try await store.search("пошив").isEmpty)
    }

    @Test func tagFilterAndTagList() async throws {
        let store = try makeStore()
        let a = try await store.create(title: "a", text: "коробка", tags: ["упаковка", "идеи"])
        let b = try await store.create(title: "b", text: "коробка два", tags: ["упаковка"])
        _ = try await store.create(title: "c", tags: [])
        let d = try await store.create(title: "d", tags: ["идеи"])
        #expect(Set(try await store.list(tag: "упаковка").map(\.id)) == [a.id, b.id])
        #expect(try await store.list(tag: "идеи").count == 2)
        #expect(try await store.list(tag: "нет").isEmpty)
        #expect(try await store.search("коробка", tag: "идеи").map(\.id) == [a.id])
        #expect(try await Set(store.allTags()) == ["идеи", "упаковка"])
        try await store.softDelete(id: d.id)
        #expect(try await store.allTags().first == "упаковка")
    }

    @Test func noteSourceIsUnique() async throws {
        let store = try makeStore()
        _ = try await store.create(title: "w", origin: "wispr", source: "wispr", sourceId: "1")
        await #expect(throws: (any Error).self) {
            _ = try await store.create(title: "w2", origin: "wispr", source: "wispr", sourceId: "1")
        }
    }

    @Test func audioURLOnlyWhenFileExists() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try makeStore(dir: dir)
        let n = try await store.create(text: "x", audioPath: "n.m4a")
        #expect(store.audioURL(for: n) == nil)
        try Data([1]).write(to: dir.appendingPathComponent("n.m4a"))
        #expect(store.audioURL(for: n) == dir.appendingPathComponent("n.m4a"))
        #expect(store.audioURL(for: Note(text: "no audio")) == nil)
    }

    @Test func firstLine() {
        #expect(Note(text: "Привет, мир. Вторая фраза.").firstLine == "Привет, мир.")
        #expect(Note(text: "Без точки\nвторая строка").firstLine == "Без точки")
        #expect(Note(text: "3.5 метра ткани").firstLine == "3.5 метра ткани")
        #expect(Note(text: nil).firstLine == "")
    }

    @Test func autoTitleFillsTitleAndTagsButKeepsUserEdits() async throws {
        let store = try makeStore()
        let llm = StubTitleChat(reply: #"{"title":"Образцы тканей: вопросы Игорю","tags":["ткани"]}"#)
        let titler = NoteTitler(llm: llm, model: "m")
        let n = try await store.create(title: "Надо не забыть спросить", text: "Надо не забыть спросить у Игоря про образцы")
        let done = try #require(try await store.autoTitle(id: n.id, titler: titler))
        #expect(done.title == "Образцы тканей: вопросы Игорю" && done.tags == ["ткани"])

        // the user retitled while the request was in flight: keep theirs
        let m = try await store.create(title: "Моё", text: "текст заметки")
        let slow = NoteTitler(llm: StubTitleChat(reply: #"{"title":"Чужой","tags":[]}"#, beforeReply: {
            _ = try? await store.update(id: m.id) { $0.title = "Моё новое" }
        }), model: "m")
        let kept = try #require(try await store.autoTitle(id: m.id, titler: slow))
        #expect(kept.title == "Моё новое")
    }
}
