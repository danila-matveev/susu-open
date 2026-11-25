import Foundation
import GRDB

/// Read-only queries behind the Stats screen (spec 1.6 «Статистика»): words, speed, streak, apps, latency.
/// Counts dictations only (not agent requests), skipping cancelled / failed ones, like `HistoryStore.counters`.
public struct StatsQueries: Sendable {
    public struct Totals: Sendable, Equatable {
        public var words: Int
        public var dictations: Int
        /// Words and milliseconds of rows that have a duration: the base for words per minute.
        public var timedWords: Int
        public var timedMs: Int
        public var wordsPerMinute: Double { timedMs > 0 ? Double(timedWords) / (Double(timedMs) / 60_000) : 0 }
    }

    public struct AppCount: Sendable, Equatable {
        public var bundleId: String?
        public var appName: String?
        public var dictations: Int
    }

    public struct LatencyPoint: Sendable, Equatable {
        /// Start of the day or week in the calendar passed to the query.
        public var start: Date
        public var medianMs: Double
        public var samples: Int
    }

    public enum LatencyBucket: Sendable { case day, week }

    public struct Streaks: Sendable, Equatable {
        /// Consecutive days with a dictation, ending today (or yesterday if today has none yet).
        public var current: Int
        public var longest: Int
    }

    public struct RecentApp: Sendable, Equatable {
        public var bundleId: String
        public var appName: String?
    }

    let database: SusuDatabase
    public init(database: SusuDatabase) { self.database = database }
    private var writer: any DatabaseWriter { database.writer }

    private static let live = "deleted_at IS NULL AND kind = 'dictation' AND status NOT IN ('cancelled','failed')"

    /// `AND created_at >= ? AND created_at < ?` for a half-open range; either end may be nil.
    private static func range(_ from: Date?, _ to: Date?) -> (String, [String]) {
        var sql = ""
        var args: [String] = []
        if let from { sql += " AND created_at >= ?"; args.append(SusuTime.string(from)) }
        if let to { sql += " AND created_at < ?"; args.append(SusuTime.string(to)) }
        return (sql, args)
    }

    // MARK: Totals

    /// Words = spaces + 1 over the final text (raw if there is none), as in `HistoryStore.counters`.
    public func totals(from: Date? = nil, to: Date? = nil) async throws -> Totals {
        let (cond, args) = Self.range(from, to)
        return try await writer.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n,
                       COALESCE(SUM(w), 0) AS words,
                       COALESCE(SUM(CASE WHEN duration_ms > 0 THEN w END), 0) AS timed_words,
                       COALESCE(SUM(CASE WHEN duration_ms > 0 THEN duration_ms END), 0) AS timed_ms
                FROM (
                    SELECT duration_ms, length(s) - length(replace(s, ' ', '')) + 1 AS w
                    FROM (
                        SELECT duration_ms,
                               replace(replace(trim(COALESCE(NULLIF(trim(final_text), ''), raw_text, '')), char(10), ' '), char(9), ' ') AS s
                        FROM dictation WHERE \(Self.live)\(cond)
                    ) WHERE s <> ''
                )
                """, arguments: StatementArguments(args))!
            return Totals(words: row["words"], dictations: row["n"], timedWords: row["timed_words"], timedMs: row["timed_ms"])
        }
    }

    // MARK: By app

    /// Dictations per app, biggest first. Rows without any app info form one entry with nil bundle and name.
    public func dictationsByApp(from: Date? = nil, to: Date? = nil) async throws -> [AppCount] {
        let (cond, args) = Self.range(from, to)
        return try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT bundle_id, MAX(app_name) AS app_name, COUNT(*) AS n
                FROM dictation WHERE \(Self.live)\(cond)
                GROUP BY COALESCE(bundle_id, app_name, '')
                ORDER BY n DESC, COALESCE(bundle_id, app_name, '')
                """, arguments: StatementArguments(args)).map {
                AppCount(bundleId: $0["bundle_id"], appName: $0["app_name"], dictations: $0["n"])
            }
        }
    }

    /// Apps seen in history, most recently used first (for the «где применять» picker).
    public func recentApps(limit: Int = 20) async throws -> [RecentApp] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT bundle_id, MAX(app_name) AS app_name, MAX(created_at) AS last
                FROM dictation WHERE \(Self.live) AND bundle_id IS NOT NULL AND bundle_id <> ''
                GROUP BY bundle_id ORDER BY last DESC LIMIT ?
                """, arguments: [limit]).map { RecentApp(bundleId: $0["bundle_id"], appName: $0["app_name"]) }
        }
    }

    // MARK: Latency

    /// Median key-release-to-insert latency per day (or week), oldest first. Buckets without data are left out.
    /// SQLite has no median, so rows are bucketed here.
    public func medianLatency(from: Date, to: Date, bucket: LatencyBucket = .day,
                              calendar: Calendar = .current) async throws -> [LatencyPoint] {
        let (cond, args) = Self.range(from, to)
        let rows: [(Date, Int)] = try await writer.read { db in
            var out: [(Date, Int)] = []
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT created_at, latency_ms FROM dictation
                WHERE \(Self.live) AND latency_ms IS NOT NULL\(cond)
                """, arguments: StatementArguments(args))
            while let r = try cursor.next() {
                let text: String = r["created_at"]
                if let date = SusuTime.date(text) { out.append((date, r["latency_ms"])) }
            }
            return out
        }
        var groups: [Date: [Int]] = [:]
        for (date, ms) in rows {
            let start: Date
            switch bucket {
            case .day: start = calendar.startOfDay(for: date)
            case .week: start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
            }
            groups[start, default: []].append(ms)
        }
        return groups.keys.sorted().map { key in
            let v = groups[key]!.sorted()
            let mid = v.count / 2
            let median = v.count % 2 == 1 ? Double(v[mid]) : Double(v[mid - 1] + v[mid]) / 2
            return LatencyPoint(start: key, medianMs: median, samples: v.count)
        }
    }

    // MARK: Streak and calendar

    /// Dictations per local calendar day, all time.
    public func dayCounts(calendar: Calendar = .current) async throws -> [Date: Int] {
        try await writer.read { db in
            var counts: [Date: Int] = [:]
            let times = try String.fetchCursor(db, sql: "SELECT created_at FROM dictation WHERE \(Self.live)")
            while let text = try times.next() {
                if let date = SusuTime.date(text) { counts[calendar.startOfDay(for: date), default: 0] += 1 }
            }
            return counts
        }
    }

    /// Current and longest run of consecutive days present in `dayCounts` (keys are start-of-day dates).
    public static func streaks(dayCounts: [Date: Int], calendar: Calendar = .current, now: Date = Date()) -> Streaks {
        let days = dayCounts.keys.sorted()
        var longest = 0, run = 0
        var previous: Date?
        for day in days {
            if let p = previous, calendar.date(byAdding: .day, value: 1, to: p) == day { run += 1 } else { run = 1 }
            longest = max(longest, run)
            previous = day
        }
        let today = calendar.startOfDay(for: now)
        var cursor = today
        if dayCounts[cursor] == nil, let yesterday = calendar.date(byAdding: .day, value: -1, to: today) { cursor = yesterday }
        var current = 0
        while dayCounts[cursor] != nil {
            current += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return Streaks(current: current, longest: longest)
    }
}
