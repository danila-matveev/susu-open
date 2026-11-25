import Foundation
import GRDB

/// Which dictations the feed / search show (spec 1.6 filters). nil / empty = no restriction.
public struct HistoryFilter: Sendable, Equatable {
    public var kind: DictationKind?
    public var bundleId: String?
    public var statuses: Set<DictationStatus>
    public var fallbackUsed: Bool?

    public init(kind: DictationKind? = nil, bundleId: String? = nil, statuses: Set<DictationStatus> = [],
                fallbackUsed: Bool? = nil) {
        self.kind = kind; self.bundleId = bundleId; self.statuses = statuses; self.fallbackUsed = fallbackUsed
    }
}

/// Position in the feed: the last row of the previous page.
public struct FeedCursor: Sendable, Equatable {
    public var createdAt: Date
    public var id: String
}

/// Rows of one local calendar day, newest first.
public struct FeedDay: Sendable, Equatable {
    /// Start of the day in the calendar passed to `feed`.
    public var day: Date
    public var items: [Dictation]
}

/// A page can end in the middle of a day: the UI appends the next page's first day to the last one if `day` matches.
public struct FeedPage: Sendable, Equatable {
    public var days: [FeedDay]
    /// nil when there is nothing older.
    public var next: FeedCursor?
}

public struct HistoryCounters: Sendable, Equatable {
    public var totalWords: Int
    public var wordsPerMinute: Double
    /// Consecutive local days with at least one dictation, ending today (or yesterday if today has none yet).
    public var streakDays: Int
}

/// History of dictations and agent requests: save, feed by day, search, counters, delete (spec 1.6, 3.8).
public final class HistoryStore: Sendable {
    let database: SusuDatabase
    /// Base for relative `audioPath` values (normally `~/Library/Application Support/Susu`).
    public let baseDirectory: URL?

    public init(database: SusuDatabase, baseDirectory: URL? = nil) {
        self.database = database
        self.baseDirectory = baseDirectory
    }

    private var writer: any DatabaseWriter { database.writer }

    // MARK: Write

    /// Inserts, or replaces the row with the same id.
    public func save(_ dictation: Dictation) async throws {
        try await writer.write { try dictation.save($0) }
    }

    public func save(_ dictations: [Dictation]) async throws {
        try await writer.write { db in for d in dictations { try d.save(db) } }
    }

    /// Reads, mutates and writes back in one transaction; `updated_at` is bumped by the trigger.
    @discardableResult
    public func update(id: String, _ mutate: @Sendable (inout Dictation) -> Void) async throws -> Dictation? {
        try await writer.write { db in
            guard var d = try Dictation.fetchOne(db, key: id), d.deletedAt == nil else { return nil }
            mutate(&d)
            d.id = id
            try d.update(db)
            return try Dictation.fetchOne(db, key: id)
        }
    }

    /// Hides the record from feed and search and deletes its audio file (spec 3.8).
    public func softDelete(id: String, now: Date = Date()) async throws {
        let path: String? = try await writer.write { db in
            guard let d = try Dictation.fetchOne(db, key: id), d.deletedAt == nil else { return nil }
            try db.execute(
                sql: "UPDATE dictation SET deleted_at = ?, audio_path = NULL WHERE id = ?",
                arguments: [SusuTime.string(now), id])
            return d.audioPath
        }
        if let path { try removeAudioFile(at: path) }
    }

    private func removeAudioFile(at path: String) throws {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : baseDirectory?.appendingPathComponent(path)
        guard let url else { return }
        do { try FileManager.default.removeItem(at: url) } catch let e as CocoaError where e.code == .fileNoSuchFile {}
    }

    // MARK: Read

    public func fetch(id: String) async throws -> Dictation? {
        try await writer.read { db in
            try Dictation.fetchOne(db, sql: "SELECT * FROM dictation WHERE id = ? AND deleted_at IS NULL", arguments: [id])
        }
    }

    /// Newest first, grouped by day of `calendar` (pass `.current` for the user's local days).
    public func feed(filter: HistoryFilter = .init(), after cursor: FeedCursor? = nil, limit: Int = 100,
                     calendar: Calendar = .current) async throws -> FeedPage {
        let rows = try await writer.read { db in
            try Self.fetchFeed(db, filter: filter, after: cursor, limit: limit)
        }
        var days: [FeedDay] = []
        for row in rows {
            let day = calendar.startOfDay(for: row.createdAt)
            if days.last?.day == day { days[days.count - 1].items.append(row) } else {
                days.append(FeedDay(day: day, items: [row]))
            }
        }
        let next = rows.count == limit ? rows.last.map { FeedCursor(createdAt: $0.createdAt, id: $0.id) } : nil
        return FeedPage(days: days, next: next)
    }

    /// Full-text search over raw / final / edited text; every word matches as a prefix ("прив" finds "привет").
    /// Newest first. Empty or symbol-only queries return nothing.
    public func search(_ query: String, filter: HistoryFilter = .init(), limit: Int = 100) async throws -> [Dictation] {
        try await writer.read { db in try Self.fetchSearch(db, query: query, filter: filter, limit: limit) }
    }

    public func counters(calendar: Calendar = .current, now: Date = Date()) async throws -> HistoryCounters {
        try await writer.read { db in try Self.fetchCounters(db, calendar: calendar, now: now) }
    }

    // MARK: Observe (for the UI)

    /// Emits the latest `limit` live records now and again after any change to them.
    public func observeChanges(filter: HistoryFilter = .init(), limit: Int = 200) -> AsyncValueObservation<[Dictation]> {
        ValueObservation
            .tracking { db in try Self.fetchFeed(db, filter: filter, after: nil, limit: limit) }
            .values(in: writer)
    }

    public func observeCounters(calendar: Calendar = .current) -> AsyncValueObservation<HistoryCounters> {
        ValueObservation
            .tracking { db in try Self.fetchCounters(db, calendar: calendar, now: Date()) }
            .values(in: writer)
    }

    // MARK: Queries

    private static let liveTexts = "status NOT IN ('cancelled','failed')"

    /// `AND ...` conditions for a filter on table alias `d`.
    private static func conditions(_ f: HistoryFilter) -> (String, [any DatabaseValueConvertible]) {
        var sql = ""
        var args: [any DatabaseValueConvertible] = []
        if let kind = f.kind { sql += " AND d.kind = ?"; args.append(kind) }
        if let b = f.bundleId { sql += " AND d.bundle_id = ?"; args.append(b) }
        if !f.statuses.isEmpty {
            sql += " AND d.status IN (" + f.statuses.map { _ in "?" }.joined(separator: ",") + ")"
            args += f.statuses.map(\.rawValue)
        }
        if let fb = f.fallbackUsed { sql += " AND d.fallback_used = ?"; args.append(fb) }
        return (sql, args)
    }

    private static func fetchFeed(_ db: Database, filter: HistoryFilter, after cursor: FeedCursor?, limit: Int) throws
        -> [Dictation] {
        var (sql, args) = conditions(filter)
        if let c = cursor {
            sql += " AND (d.created_at, d.id) < (?, ?)"
            args += [SusuTime.string(c.createdAt), c.id]
        }
        args.append(limit)
        return try Dictation.fetchAll(
            db,
            sql: "SELECT d.* FROM dictation d WHERE d.deleted_at IS NULL\(sql) ORDER BY d.created_at DESC, d.id DESC LIMIT ?",
            arguments: StatementArguments(args))
    }

    /// Letters and digits only, each as a quoted prefix term: nothing the user types can break FTS5 syntax.
    static func ftsPattern(_ query: String) -> String? {
        let terms = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { "\"\($0)\"*" }
        return terms.isEmpty ? nil : terms.joined(separator: " ")
    }

    private static func fetchSearch(_ db: Database, query: String, filter: HistoryFilter, limit: Int) throws
        -> [Dictation] {
        guard let pattern = ftsPattern(query) else { return [] }
        var (sql, args) = conditions(filter)
        args.insert(pattern, at: 0)
        args.append(limit)
        return try Dictation.fetchAll(
            db,
            sql: """
                SELECT d.* FROM dictation_fts JOIN dictation d ON d.rowid = dictation_fts.rowid
                WHERE dictation_fts MATCH ? AND d.deleted_at IS NULL\(sql)
                ORDER BY d.created_at DESC, d.id DESC LIMIT ?
                """,
            arguments: StatementArguments(args))
    }

    private static func fetchCounters(_ db: Database, calendar: Calendar, now: Date) throws -> HistoryCounters {
        // Words = spaces + 1 over final text (raw if no final); newlines/tabs count as spaces.
        let row = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(w), 0) AS words,
                   COALESCE(SUM(CASE WHEN duration_ms > 0 THEN w END), 0) AS timed_words,
                   COALESCE(SUM(CASE WHEN duration_ms > 0 THEN duration_ms END), 0) AS timed_ms
            FROM (
                SELECT duration_ms, length(s) - length(replace(s, ' ', '')) + 1 AS w
                FROM (
                    SELECT duration_ms,
                           replace(replace(trim(COALESCE(NULLIF(trim(final_text), ''), raw_text, '')), char(10), ' '), char(9), ' ') AS s
                    FROM dictation
                    WHERE deleted_at IS NULL AND kind = 'dictation' AND \(liveTexts)
                ) WHERE s <> ''
            )
            """)!
        let words: Int = row["words"]
        let timedWords: Int = row["timed_words"]
        let timedMs: Int = row["timed_ms"]
        let wpm = timedMs > 0 ? Double(timedWords) / (Double(timedMs) / 60_000) : 0

        // Streak: walk days newest -> oldest and stop at the first gap (reads only as many rows as the streak spans).
        let today = calendar.startOfDay(for: now)
        var expected = today
        var streak = 0
        let times = try String.fetchCursor(
            db, sql: "SELECT created_at FROM dictation WHERE deleted_at IS NULL AND kind = 'dictation' AND \(liveTexts) ORDER BY created_at DESC")
        while let text = try times.next(), let date = SusuTime.date(text) {
            let day = calendar.startOfDay(for: date)
            if day > expected { continue }  // future-dated row (clock skew)
            if day == expected {
                streak += 1
                guard let prev = calendar.date(byAdding: .day, value: -1, to: expected) else { break }
                expected = prev
            } else if streak == 0, day == calendar.date(byAdding: .day, value: -1, to: today) {
                // nothing yet today: the streak may still end yesterday
                streak = 1
                guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
                expected = prev
            } else if day < expected {
                break
            }
        }
        return HistoryCounters(totalWords: words, wordsPerMinute: wpm, streakDays: streak)
    }
}
