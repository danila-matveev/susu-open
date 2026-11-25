import Foundation
import Testing
@testable import SusuCore

@Suite struct DictionaryServiceTests {
    static func make() throws -> DictionaryService { DictionaryService(database: try SusuDatabase.inMemory()) }
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    @Test func addAndListWithOriginFilterAndSearch() async throws {
        let d = try Self.make()
        try await d.add(phrase: "Lumera", origin: "manual", now: Self.at(0))
        try await d.add(kind: "replacement", phrase: "Яндекс Печкид", replacement: "SpeechKit", origin: "learned", now: Self.at(1))
        try await d.add(kind: "snippet", phrase: "мой адрес", replacement: "ул. Пример 1", now: Self.at(2))
        #expect(try await d.list().count == 3)
        #expect(try await d.list(origin: "learned").map(\.phrase) == ["Яндекс Печкид"])
        #expect(try await d.list(kind: "snippet").count == 1)
        #expect(try await d.list(query: "speechkit").map(\.phrase) == ["Яндекс Печкид"])
        #expect(try await d.list(query: "LUME").map(\.phrase) == ["Lumera"])
        #expect(try await d.list(query: "ПЕЧКИД").count == 1)
    }

    @Test func addDoesNotDuplicate() async throws {
        let d = try Self.make()
        let a = try await d.add(phrase: "Lumera")
        let b = try await d.add(phrase: "  lumera ")
        let c1 = try await d.add(phrase: "Яндекс Печкид"); let c2 = try await d.add(phrase: "яндекс печкид")
        #expect(c1.id == c2.id)
        #expect(a.id == b.id)
        #expect(try await d.list().count == 2)
    }

    @Test func softDeleteHidesAndRestoreBringsBack() async throws {
        let d = try Self.make()
        let e = try await d.add(phrase: "Groq")
        try await d.softDelete(id: e.id)
        #expect(try await d.list().isEmpty)
        #expect(try await d.entry(id: e.id) == nil)
        #expect(try await d.hintTerms().isEmpty)
        let back = try await d.restore(id: e.id)
        #expect(back?.phrase == "Groq" && back?.deletedAt == nil)
        #expect(try await d.list().count == 1)
        // After a delete the same phrase can be added again as a fresh entry.
        try await d.softDelete(id: e.id)
        let again = try await d.add(phrase: "Groq")
        #expect(again.id != e.id)
    }

    @Test func recordUseIncrements() async throws {
        let d = try Self.make()
        let a = try await d.add(phrase: "A")
        let b = try await d.add(phrase: "B")
        try await d.recordUse(ids: [a.id, a.id, b.id])
        try await d.recordUse(ids: [a.id])
        #expect(try await d.entry(id: a.id)?.useCount == 3)
        #expect(try await d.entry(id: b.id)?.useCount == 1)
    }

    @Test func hintTermsOrderStarredThenUseThenRecent() async throws {
        let d = try Self.make()
        try await d.add(phrase: "old", now: Self.at(0))
        try await d.add(phrase: "fresh", now: Self.at(100))
        let used = try await d.add(phrase: "used", now: Self.at(50))
        let star = try await d.add(phrase: "star", now: Self.at(10))
        let fix = try await d.add(kind: "replacement", phrase: "печкид", replacement: "SpeechKit", now: Self.at(60))
        try await d.add(kind: "snippet", phrase: "sig", replacement: "long text")
        try await d.setStarred(id: star.id, true)
        try await d.recordUse(ids: [used.id, used.id, used.id])
        try await d.recordUse(ids: [fix.id])
        #expect(try await d.hintTerms() == ["star", "used", "SpeechKit", "fresh", "old"])
        #expect(try await d.hintTerms(limit: 2) == ["star", "used"])
    }

    @Test func hintTermsDeduplicatesCaseInsensitively() async throws {
        let d = try Self.make()
        try await d.add(phrase: "SpeechKit", now: Self.at(0))
        try await d.add(kind: "replacement", phrase: "печкид", replacement: "speechkit", now: Self.at(1))
        #expect(try await d.hintTerms().count == 1)
    }

    @Test func replacementsAndSnippets() async throws {
        let d = try Self.make()
        try await d.add(kind: "replacement", phrase: "клод код", replacement: "Claude Code")
        try await d.add(kind: "snippet", phrase: "мой адрес", replacement: "ул. Пример 1")
        try await d.add(phrase: "Susu")
        let r = try await d.replacements()
        #expect(r.count == 1 && r[0].phrase == "клод код" && r[0].replacement == "Claude Code")
        #expect(try await d.snippets().map(\.phrase) == ["мой адрес"])
    }

    @Test func editorExamplesAreFreshestLearnedReplacements() async throws {
        let d = try Self.make()
        for i in 0..<12 {
            try await d.add(kind: "replacement", phrase: "w\(i)", replacement: "R\(i)", origin: "learned", now: Self.at(Double(i)))
        }
        try await d.add(kind: "replacement", phrase: "manual", replacement: "Manual", origin: "manual", now: Self.at(500))
        try await d.add(phrase: "justword", origin: "learned", now: Self.at(600))
        let ex = try await d.editorExamples()
        #expect(ex.count == 10)
        #expect(ex[0].before == "w11" && ex[0].after == "R11")
        #expect(ex[9].before == "w2")
        #expect(try await d.editorExamples(limit: 3).count == 3)
    }

    @Test func updateEditsEntry() async throws {
        let d = try Self.make()
        let e = try await d.add(phrase: "speachkit")
        let u = try await d.update(id: e.id) { $0.phrase = "SpeechKit"; $0.starred = true }
        #expect(u?.phrase == "SpeechKit" && u?.starred == true)
    }

    @Test func knownPhrasesIncludeTriggersAndTargets() async throws {
        let d = try Self.make()
        try await d.add(kind: "replacement", phrase: "Клод Код", replacement: "Claude Code")
        try await d.add(kind: "snippet", phrase: "адрес", replacement: "x")
        #expect(try await d.knownPhrases() == ["клод код", "claude code"])
    }
}
