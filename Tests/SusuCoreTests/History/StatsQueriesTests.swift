import Foundation
import Testing
@testable import SusuCore

@Suite struct StatsQueriesTests {
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2  // Monday
        return c
    }
    static func date(_ s: String) -> Date { SusuTime.date(s)! }

    func make() throws -> (HistoryStore, StatsQueries) {
        let db = try SusuDatabase.inMemory()
        return (HistoryStore(database: db), StatsQueries(database: db))
    }

    @Test func totalsCountWordsSpeedAndSkipDeadRows() async throws {
        let (history, stats) = try make()
        try await history.save([
            // 4 words in 2 s, 6 words in 3 s -> 10 words in 5 s = 120 wpm
            Dictation(id: "a", createdAt: Self.date("2026-11-10T10:00:00.000Z"), durationMs: 2000, rawText: "раз два три четыре"),
            Dictation(id: "b", createdAt: Self.date("2026-11-10T11:00:00.000Z"), durationMs: 3000, rawText: "x",
                      finalText: "один два три\nчетыре пять шесть"),
            Dictation(id: "c", createdAt: Self.date("2026-11-11T11:00:00.000Z"), rawText: "без длительности тут"),   // counts words, not speed
            Dictation(id: "d", kind: .agent, createdAt: Self.date("2026-11-11T12:00:00.000Z"), durationMs: 1000, rawText: "агент"),
            Dictation(id: "e", createdAt: Self.date("2026-11-11T13:00:00.000Z"), status: .cancelled, rawText: "отмена"),
            Dictation(id: "f", createdAt: Self.date("2026-11-11T14:00:00.000Z"), status: .failed, rawText: "сбой"),
            Dictation(id: "g", createdAt: Self.date("2026-11-11T15:00:00.000Z"), rawText: "   "),
        ])
        try await history.softDelete(id: "g")
        let t = try await stats.totals()
        #expect(t.dictations == 3)
        #expect(t.words == 13)
        #expect(t.timedWords == 10 && t.timedMs == 5000)
        #expect(abs(t.wordsPerMinute - 120) < 0.001)

        let day = try await stats.totals(from: Self.date("2026-11-11T00:00:00.000Z"), to: Self.date("2026-11-12T00:00:00.000Z"))
        #expect(day.dictations == 1 && day.words == 3 && day.wordsPerMinute == 0)

        let none = try await stats.totals(from: Self.date("2027-01-01T00:00:00.000Z"))
        #expect(none == StatsQueries.Totals(words: 0, dictations: 0, timedWords: 0, timedMs: 0))
    }

    @Test func byAppGroupsAndOrders() async throws {
        let (history, stats) = try make()
        func d(_ id: String, _ bundle: String?, _ name: String?, day: Int = 10) -> Dictation {
            Dictation(id: id, createdAt: Self.date("2026-11-\(day)T10:00:00.000Z"), appName: name, bundleId: bundle, rawText: "слово")
        }
        try await history.save([
            d("1", "tg", "Telegram"), d("2", "tg", "Telegram"), d("3", "tg", "Telegram", day: 12),
            d("4", "cursor", "Cursor"), d("5", "cursor", "Cursor"),
            d("6", nil, "Mystery"), d("7", nil, nil), d("8", nil, nil),
        ])
        let all = try await stats.dictationsByApp()
        #expect(all.map(\.dictations) == [3, 2, 2, 1])
        #expect(all[0] == .init(bundleId: "tg", appName: "Telegram", dictations: 3))
        // Ties are ordered by key: rows with no app info ('') come before "cursor".
        #expect(all[1] == .init(bundleId: nil, appName: nil, dictations: 2))
        #expect(all[2] == .init(bundleId: "cursor", appName: "Cursor", dictations: 2))
        #expect(all[3] == .init(bundleId: nil, appName: "Mystery", dictations: 1))
        let ranged = try await stats.dictationsByApp(from: Self.date("2026-11-11T00:00:00.000Z"))
        #expect(ranged == [.init(bundleId: "tg", appName: "Telegram", dictations: 1)])
    }

    @Test func recentAppsNewestFirst() async throws {
        let (history, stats) = try make()
        try await history.save([
            Dictation(id: "1", createdAt: Self.date("2026-11-01T10:00:00.000Z"), appName: "Old", bundleId: "old", rawText: "a"),
            Dictation(id: "2", createdAt: Self.date("2026-11-09T10:00:00.000Z"), appName: "New", bundleId: "new", rawText: "a"),
            Dictation(id: "3", createdAt: Self.date("2026-11-05T10:00:00.000Z"), appName: "Old", bundleId: "old", rawText: "a"),
            Dictation(id: "4", createdAt: Self.date("2026-11-10T10:00:00.000Z"), rawText: "no app"),
        ])
        #expect(try await stats.recentApps().map(\.bundleId) == ["new", "old"])
        #expect(try await stats.recentApps(limit: 1).count == 1)
    }

    @Test func medianLatencyPerDay() async throws {
        let (history, stats) = try make()
        func d(_ id: String, _ ts: String, _ ms: Int?) -> Dictation {
            Dictation(id: id, createdAt: Self.date(ts), rawText: "слово", latencyMs: ms)
        }
        try await history.save([
            d("1", "2026-11-10T08:00:00.000Z", 900), d("2", "2026-11-10T09:00:00.000Z", 300), d("3", "2026-11-10T23:30:00.000Z", 500),  // odd: median 500
            d("4", "2026-11-11T08:00:00.000Z", 400), d("5", "2026-11-11T09:00:00.000Z", 600),                                         // even: 500
            d("6", "2026-11-11T10:00:00.000Z", nil),                                                                                  // no latency: ignored
            d("7", "2026-11-13T08:00:00.000Z", 700),                                                                                  // gap on the 12th
            d("8", "2026-11-05T08:00:00.000Z", 100),                                                                                  // outside range
        ])
        let pts = try await stats.medianLatency(from: Self.date("2026-11-07T00:00:00.000Z"),
                                                to: Self.date("2026-11-14T00:00:00.000Z"), calendar: Self.utc)
        #expect(pts.map(\.medianMs) == [500, 500, 700])
        #expect(pts.map(\.samples) == [3, 2, 1])
        #expect(pts.map(\.start) == ["2026-11-10", "2026-11-11", "2026-11-13"].map { Self.date($0 + "T00:00:00.000Z") })
    }

    @Test func medianLatencyUsesLocalDays() async throws {
        let (history, stats) = try make()
        // 23:30 UTC on the 10th is already the 11th at UTC+3.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
        try await history.save([Dictation(id: "1", createdAt: Self.date("2026-11-10T23:30:00.000Z"), rawText: "x", latencyMs: 400)])
        let pts = try await stats.medianLatency(from: Self.date("2026-11-01T00:00:00.000Z"),
                                                to: Self.date("2026-12-01T00:00:00.000Z"), calendar: cal)
        #expect(pts.count == 1)
        #expect(cal.component(.day, from: pts[0].start) == 11)
    }

    @Test func medianLatencyPerWeek() async throws {
        let (history, stats) = try make()
        func d(_ id: String, _ ts: String, _ ms: Int) -> Dictation {
            Dictation(id: id, createdAt: Self.date(ts), rawText: "слово", latencyMs: ms)
        }
        // Mon 2026-11-02 week: 100, 300, 900 -> 300. Mon 2026-11-09 week: 500.
        try await history.save([
            d("1", "2026-11-02T08:00:00.000Z", 100), d("2", "2026-11-04T08:00:00.000Z", 900), d("3", "2026-11-08T22:00:00.000Z", 300),
            d("4", "2026-11-09T01:00:00.000Z", 500),
        ])
        let pts = try await stats.medianLatency(from: Self.date("2026-10-01T00:00:00.000Z"),
                                                to: Self.date("2026-12-01T00:00:00.000Z"), bucket: .week, calendar: Self.utc)
        #expect(pts.map(\.medianMs) == [300, 500])
        #expect(pts[0].start == Self.date("2026-11-02T00:00:00.000Z"))
    }

    @Test func dayCountsAndStreaks() async throws {
        let (history, stats) = try make()
        // Days: Oct 28, 29 (run of 2), then Nov 8, 9, 10, 11 (run of 4), today = Nov 12 with nothing yet.
        var rows: [Dictation] = []
        for (i, day) in ["2026-10-28", "2026-10-29", "2026-11-08", "2026-11-09", "2026-11-10", "2026-11-11"].enumerated() {
            rows.append(Dictation(id: "a\(i)", createdAt: Self.date(day + "T10:00:00.000Z"), rawText: "x"))
        }
        rows.append(Dictation(id: "b", createdAt: Self.date("2026-11-11T12:00:00.000Z"), rawText: "x"))
        rows.append(Dictation(id: "c", createdAt: Self.date("2026-11-11T13:00:00.000Z"), status: .failed, rawText: "x"))
        try await history.save(rows)

        let counts = try await stats.dayCounts(calendar: Self.utc)
        #expect(counts.count == 6)
        #expect(counts[Self.date("2026-11-11T00:00:00.000Z")] == 2)

        let noon = Self.date("2026-11-12T12:00:00.000Z")
        #expect(StatsQueries.streaks(dayCounts: counts, calendar: Self.utc, now: noon) == .init(current: 4, longest: 4))

        // A dictation today extends the streak; a gap day ends it.
        var withToday = counts
        withToday[Self.date("2026-11-12T00:00:00.000Z")] = 1
        #expect(StatsQueries.streaks(dayCounts: withToday, calendar: Self.utc, now: noon).current == 5)
        let later = Self.date("2026-11-14T12:00:00.000Z")
        #expect(StatsQueries.streaks(dayCounts: counts, calendar: Self.utc, now: later).current == 0)
        #expect(StatsQueries.streaks(dayCounts: [:], calendar: Self.utc, now: noon) == .init(current: 0, longest: 0))

        // The longest run can be an old one.
        var old = counts
        for d in 1...6 { old[Self.date("2026-09-0\(d)T00:00:00.000Z")] = 1 }
        #expect(StatsQueries.streaks(dayCounts: old, calendar: Self.utc, now: noon) == .init(current: 4, longest: 6))
    }

    @Test func streakAgreesWithHistoryCounters() async throws {
        let (history, stats) = try make()
        var rows: [Dictation] = []
        for d in 8...12 { rows.append(Dictation(id: "r\(d)", createdAt: Self.date("2026-11-\(d < 10 ? "0" : "")\(d)T09:00:00.000Z"), rawText: "x")) }
        try await history.save(rows)
        let now = Self.date("2026-11-12T20:00:00.000Z")
        let counters = try await history.counters(calendar: Self.utc, now: now)
        let streaks = StatsQueries.streaks(dayCounts: try await stats.dayCounts(calendar: Self.utc), calendar: Self.utc, now: now)
        #expect(counters.streakDays == streaks.current && streaks.current == 5)
    }
}
