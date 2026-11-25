import Foundation
import GRDB
import Testing
@testable import SusuCore

@Suite struct HistoryStoreTests {
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func makeStore(dir: URL? = nil) throws -> HistoryStore {
        HistoryStore(database: try SusuDatabase.inMemory(), baseDirectory: dir)
    }

    static func date(_ s: String) -> Date { SusuTime.date(s)! }

    @Test func saveFetchUpdate() async throws {
        let store = try makeStore()
        let d = Dictation(id: "1", mode: .hold, appName: "Telegram", rawText: "привет мир", finalText: "Привет, мир.", latencyMs: 640)
        try await store.save(d)
        let got = try #require(try await store.fetch(id: "1"))
        #expect(got.finalText == "Привет, мир." && got.latencyMs == 640 && got.mode == .hold)
        let upd = try await store.update(id: "1") { $0.editedText = "Привет, мир!"; $0.status = .copiedOnly }
        #expect(upd?.editedText == "Привет, мир!" && upd?.status == .copiedOnly)
        #expect(try await store.update(id: "nope") { _ in } == nil)
    }

    @Test func searchFindsRawFinalAndEditedWithPrefixes() async throws {
        let store = try makeStore()
        try await store.save([
            Dictation(id: "r", rawText: "купить молоко завтра"),
            Dictation(id: "f", rawText: "x", finalText: "Позвонить Ивану"),
            Dictation(id: "e", rawText: "y", finalText: "z", editedText: "Отправить отчёт"),
        ])
        #expect(try await store.search("молоко").map(\.id) == ["r"])
        #expect(try await store.search("иван").map(\.id) == ["f"])  // prefix + case folding
        #expect(try await store.search("отчёт").map(\.id) == ["e"])
        #expect(try await store.search("отправить отч").map(\.id) == ["e"])  // AND of prefixes
        #expect(try await store.search("нет такого").isEmpty)
        // Hostile / empty input never throws.
        for q in ["", "   ", "\"", "a AND", "(", "*", "foo\" OR \"bar", "NEAR(", "col:x", "-", "'; DROP TABLE dictation;--"] {
            _ = try await store.search(q)
        }
        // Edits are re-indexed.
        try await store.update(id: "r") { $0.rawText = "купить хлеб" }
        #expect(try await store.search("молоко").isEmpty)
        #expect(try await store.search("хлеб").map(\.id) == ["r"])
    }

    @Test func filtersApplyToFeedAndSearch() async throws {
        let store = try makeStore()
        try await store.save([
            Dictation(id: "1", createdAt: Self.date("2026-01-01T10:00:00.000Z"), status: .inserted, bundleId: "tg", rawText: "alpha"),
            Dictation(id: "2", createdAt: Self.date("2026-01-01T11:00:00.000Z"), status: .notInserted, bundleId: "tg", rawText: "alpha"),
            Dictation(id: "3", kind: .agent, createdAt: Self.date("2026-01-01T12:00:00.000Z"), status: .inserted, bundleId: "mail", fallbackUsed: true, rawText: "alpha"),
        ])
        func ids(_ f: HistoryFilter) async throws -> [String] {
            let feed = try await store.feed(filter: f, calendar: Self.utc).days.flatMap(\.items).map(\.id)
            let found = try await store.search("alpha", filter: f).map(\.id)
            #expect(feed == found)
            return feed
        }
        #expect(try await ids(.init()) == ["3", "2", "1"])
        #expect(try await ids(.init(kind: .agent)) == ["3"])
        #expect(try await ids(.init(bundleId: "tg")) == ["2", "1"])
        #expect(try await ids(.init(statuses: [.notInserted, .failed])) == ["2"])
        #expect(try await ids(.init(fallbackUsed: true)) == ["3"])
        #expect(try await ids(.init(kind: .dictation, bundleId: "tg", statuses: [.inserted])) == ["1"])
    }

    @Test func feedGroupsByLocalDayAndPages() async throws {
        let store = try makeStore()
        // São Paulo is UTC-3: 01:00Z on the 2nd is still the 1st locally.
        var sp = Calendar(identifier: .gregorian)
        sp.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        try await store.save([
            Dictation(id: "a", createdAt: Self.date("2026-03-01T15:00:00.000Z")),
            Dictation(id: "b", createdAt: Self.date("2026-03-02T01:00:00.000Z")),
            Dictation(id: "c", createdAt: Self.date("2026-03-02T12:00:00.000Z")),
            Dictation(id: "d", createdAt: Self.date("2026-03-03T12:00:00.000Z")),
        ])
        let local = try await store.feed(calendar: sp)
        #expect(local.days.map { $0.items.map(\.id) } == [["d"], ["c"], ["b", "a"]])
        #expect(local.next == nil)
        let utc = try await store.feed(calendar: Self.utc)
        #expect(utc.days.map { $0.items.map(\.id) } == [["d"], ["c", "b"], ["a"]])

        let p1 = try await store.feed(limit: 3, calendar: Self.utc)
        #expect(p1.days.flatMap(\.items).map(\.id) == ["d", "c", "b"])
        let p2 = try await store.feed(after: p1.next, limit: 3, calendar: Self.utc)
        #expect(p2.days.flatMap(\.items).map(\.id) == ["a"] && p2.next == nil)
    }

    @Test func softDeleteHidesAndRemovesAudio() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try makeStore(dir: dir)
        let rel = "audio/dictations/2026/03/x.m4a"
        let file = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: file)
        let abs = dir.appendingPathComponent("abs.m4a")
        try Data([4]).write(to: abs)
        try await store.save([
            Dictation(id: "rel", rawText: "secret words", audioPath: rel),
            Dictation(id: "abs", rawText: "secret words", audioPath: abs.path),
            Dictation(id: "gone", rawText: "secret words", audioPath: "audio/missing.m4a"),
            Dictation(id: "keep", rawText: "secret words"),
        ])
        for id in ["rel", "abs", "gone"] { try await store.softDelete(id: id) }
        try await store.softDelete(id: "rel")  // second call is a no-op
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: abs.path))
        #expect(try await store.fetch(id: "rel") == nil)
        #expect(try await store.search("secret").map(\.id) == ["keep"])
        #expect(try await store.feed().days.flatMap(\.items).map(\.id) == ["keep"])
        // Row stays in the table (sync + 30-day purge), with deleted_at set and audio_path cleared.
        let (deletedAt, audioPath) = try await store.database.writer.read { db -> (String?, String?) in
            let r = try Row.fetchOne(db, sql: "SELECT deleted_at, audio_path FROM dictation WHERE id='rel'")!
            return (r["deleted_at"], r["audio_path"])
        }
        #expect(deletedAt != nil && audioPath == nil)
    }

    @Test func countersOnSmallData() async throws {
        let store = try makeStore()
        let now = Self.date("2026-06-10T15:00:00.000Z")
        func d(_ id: String, _ day: String, words: String, ms: Int?, status: DictationStatus = .inserted, kind: DictationKind = .dictation) -> Dictation {
            Dictation(id: id, kind: kind, createdAt: Self.date("2026-06-\(day)T12:00:00.000Z"), durationMs: ms, status: status, finalText: words)
        }
        try await store.save([
            d("a", "10", words: "one two three four five", ms: 30_000),      // 5 words, 0.5 min
            d("b", "09", words: "six seven\neight nine", ms: 30_000),        // 4 words, 0.5 min
            d("c", "08", words: "ten", ms: 60_000),                           // 1 word, 1 min
            d("x", "07", words: "skipped by gap", ms: 60_000),                // day 07 is in the data...
            d("old", "05", words: "old old old", ms: 60_000),                 // ...but 06 is missing: streak = 4
            d("fail", "10", words: "fail fail", ms: 10_000, status: .failed), // not counted
            d("agent", "10", words: "agent agent", ms: 10_000, kind: .agent), // not counted
            d("nodur", "10", words: "no duration here", ms: nil),             // words yes, minutes no
        ])
        let c = try await store.counters(calendar: Self.utc, now: now)
        #expect(c.totalWords == 5 + 4 + 1 + 3 + 3 + 3)
        // timed: (5+4+1+3+3) words over (0.5+0.5+1+1+1) minutes = 16 / 4
        #expect(abs(c.wordsPerMinute - 4.0) < 0.001)
        #expect(c.streakDays == 4)

        // Nothing today yet: streak still counts through yesterday.
        let c2 = try await store.counters(calendar: Self.utc, now: Self.date("2026-06-11T08:00:00.000Z"))
        #expect(c2.streakDays == 4)
        // Two idle days: streak is gone.
        let c3 = try await store.counters(calendar: Self.utc, now: Self.date("2026-06-12T08:00:00.000Z"))
        #expect(c3.streakDays == 0)
        // Empty database.
        let empty = try await makeStore().counters()
        #expect(empty == HistoryCounters(totalWords: 0, wordsPerMinute: 0, streakDays: 0))
    }

    @Test func observeChangesEmitsOnSave() async throws {
        let store = try makeStore()
        var it = store.observeChanges().makeAsyncIterator()
        #expect(try await it.next()?.isEmpty == true)
        try await store.save(Dictation(id: "1", rawText: "hi"))
        #expect(try await it.next()?.map(\.id) == ["1"])
        try await store.softDelete(id: "1")
        #expect(try await it.next()?.isEmpty == true)
    }

    @Test func searchIn30kRecordsIsFast() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(database: try SusuDatabase(url: dir.appendingPathComponent("susu.sqlite")))
        let vocab = ["привет", "встреча", "проект", "отчёт", "завтра", "клиент", "договор", "бюджет", "звонок", "задача",
                     "hello", "meeting", "deadline", "budget", "review", "release", "invoice", "design", "server", "today"]
        var rng = SystemRandomNumberGenerator()
        let start = Self.date("2025-01-01T00:00:00.000Z")
        var batch: [Dictation] = []
        for i in 0..<30_000 {
            let text = (0..<18).map { _ in vocab.randomElement(using: &rng)! }.joined(separator: " ")
            batch.append(Dictation(
                id: "id-\(i)", createdAt: start.addingTimeInterval(Double(i) * 600), durationMs: 8000,
                bundleId: "app\(i % 7)", rawText: text, finalText: text.capitalized))
        }
        batch[29_999].rawText = "уникальноеслово в конце"
        try await store.save(batch)

        let clock = ContinuousClock()
        var worst = Duration.zero
        for q in ["бюджет", "бюдж", "meeting deadline", "уникальноеслово", "отчёт клиент", "hel"] {
            let t0 = clock.now
            let hits = try await store.search(q, limit: 100)
            let dt = clock.now - t0
            worst = max(worst, dt)
            #expect(!hits.isEmpty, "no hits for \(q)")
        }
        let filtered = clock.now
        _ = try await store.search("проект", filter: .init(bundleId: "app3"), limit: 100)
        worst = max(worst, clock.now - filtered)
        print("search worst over 30k records: \(worst)")
        #expect(worst < .milliseconds(300))

        let t0 = clock.now
        _ = try await store.counters(calendar: Self.utc)
        _ = try await store.feed(limit: 100)
        print("counters+feed over 30k records: \(clock.now - t0)")
    }
}
