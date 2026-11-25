import Foundation
import Testing
@testable import SusuCore

@Suite struct HistoryQueriesTests {
    static var utc: Calendar { HistoryStoreTests.utc }
    static func date(_ s: String) -> Date { SusuTime.date(s)! }

    @Test func appsAreDistinctAndSortedByUse() async throws {
        let store = HistoryStore(database: try SusuDatabase.inMemory())
        try await store.save([
            Dictation(id: "1", appName: "Telegram", bundleId: "tg"),
            Dictation(id: "2", appName: "Telegram", bundleId: "tg"),
            Dictation(id: "3", appName: "Chrome", bundleId: "ch"),
            Dictation(id: "4", appName: nil, bundleId: nil),
            Dictation(id: "5", appName: "Gone", bundleId: "gone", deletedAt: Date()),
        ])
        let apps = try await store.apps()
        #expect(apps.map(\.bundleId) == ["tg", "ch"])
        #expect(apps.map(\.count) == [2, 1])
        #expect(apps[0].appName == "Telegram")
    }

    @Test func summaryCountsRecordsAndLocalDays() async throws {
        let store = HistoryStore(database: try SusuDatabase.inMemory())
        try await store.save([
            Dictation(id: "1", createdAt: Self.date("2026-01-01T10:00:00.000Z"), bundleId: "a"),
            Dictation(id: "2", createdAt: Self.date("2026-01-01T23:50:00.000Z"), bundleId: "a"),
            Dictation(id: "3", createdAt: Self.date("2026-01-02T00:10:00.000Z"), bundleId: "b"),
            Dictation(id: "4", createdAt: Self.date("2026-01-04T12:00:00.000Z"), status: .notInserted, bundleId: "b"),
        ])
        let all = try await store.summary(calendar: Self.utc)
        #expect(all == HistorySummary(count: 4, days: 3))
        #expect(try await store.summary(filter: .init(bundleId: "b"), calendar: Self.utc) == HistorySummary(count: 2, days: 2))
        #expect(try await store.summary(filter: .init(statuses: [.notInserted]), calendar: Self.utc).count == 1)
        // Same instants, UTC+3: 23:50Z and 00:10Z fall on different local days from 10:00Z -> 2026-01-02 03:10 / 02:50.
        var msk = Calendar(identifier: .gregorian)
        msk.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
        // local days: 01-01 (13:00), 01-02 (02:50), 01-02 (03:10), 01-04 (15:00) -> 3 days
        #expect(try await store.summary(calendar: msk).days == 3)
        #expect(try await store.summary(filter: .init(kind: .agent), calendar: Self.utc) == HistorySummary(count: 0, days: 0))
    }

    @Test func audioURLOnlyForExistingFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0]).write(to: dir.appendingPathComponent("a.wav"))
        let store = HistoryStore(database: try SusuDatabase.inMemory(), baseDirectory: dir)
        #expect(store.audioURL(for: Dictation(audioPath: "a.wav"))?.lastPathComponent == "a.wav")
        #expect(store.audioURL(for: Dictation(audioPath: "missing.wav")) == nil)
        #expect(store.audioURL(for: Dictation(audioPath: nil)) == nil)
        #expect(store.audioURL(for: Dictation(audioPath: dir.appendingPathComponent("a.wav").path)) != nil)
    }
}
