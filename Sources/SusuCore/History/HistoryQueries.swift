import Foundation
import GRDB

// Small read helpers the History screen needs on top of HistoryStore.

/// One program that appears in the history (for the "Program" dropdown).
public struct HistoryAppEntry: Sendable, Equatable, Identifiable {
    public var bundleId: String
    public var appName: String
    public var count: Int
    public var id: String { bundleId }
}

/// «N записей за M дня».
public struct HistorySummary: Sendable, Equatable {
    public var count: Int
    public var days: Int
    public init(count: Int, days: Int) { self.count = count; self.days = days }
}

extension HistoryStore {
    /// Distinct programs (by bundle id) of live records, most used first. Records without a bundle id are skipped.
    public func apps() async throws -> [HistoryAppEntry] {
        try await database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT bundle_id, COALESCE(MAX(app_name), bundle_id) AS name, COUNT(*) AS n
                FROM dictation WHERE deleted_at IS NULL AND bundle_id IS NOT NULL AND bundle_id <> ''
                GROUP BY bundle_id ORDER BY n DESC, name COLLATE NOCASE
                """).map { HistoryAppEntry(bundleId: $0["bundle_id"], appName: $0["name"], count: $0["n"]) }
        }
    }

    /// Number of live records matching the filter and the number of local days they span.
    public func summary(filter: HistoryFilter = .init(), calendar: Calendar = .current) async throws -> HistorySummary {
        // Days are counted from 15-minute buckets: every real UTC offset is a multiple of 15 minutes,
        // so a bucket never straddles local midnight, and the query returns a few hundred rows at most.
        let (count, buckets): (Int, [String]) = try await database.writer.read { db in
            var (cond, args) = Self.summaryConditions(filter)
            let n = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM dictation d WHERE d.deleted_at IS NULL\(cond)",
                arguments: StatementArguments(args)) ?? 0
            let b = try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT substr(d.created_at, 1, 14) || printf('%02d', (CAST(substr(d.created_at, 15, 2) AS INTEGER) / 15) * 15)
                    FROM dictation d WHERE d.deleted_at IS NULL\(cond)
                    """,
                arguments: StatementArguments(args))
            return (n, b)
        }
        var days = Set<Date>()
        for b in buckets {
            if let date = SusuTime.date(b + ":00.000Z") { days.insert(calendar.startOfDay(for: date)) }
        }
        return HistorySummary(count: count, days: days.count)
    }

    /// File of a record's audio if it still exists on disk.
    public func audioURL(for d: Dictation) -> URL? {
        guard let path = d.audioPath, !path.isEmpty else { return nil }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : baseDirectory?.appendingPathComponent(path)
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static func summaryConditions(_ f: HistoryFilter) -> (String, [any DatabaseValueConvertible]) {
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
}
