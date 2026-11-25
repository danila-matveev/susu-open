// Audio retention (spec 1.6 «Данные и приватность»): audio older than N days is deleted, the text stays.
// The app calls `run` at launch and once a day.
import Foundation
import GRDB

public enum AudioRetention {
    /// `Settings.audioRetentionDays` value that means «keep audio forever».
    public static let forever = 0

    public struct Result: Sendable, Equatable {
        public var clearedRows: Int
        public var deletedFiles: Int
    }

    /// Cutoff date for a retention setting; nil when audio is kept forever.
    public static func cutoff(days: Int, now: Date = Date()) -> Date? {
        days <= forever ? nil : now.addingTimeInterval(-Double(days) * 86_400)
    }

    /// Applies the setting. Does nothing for «forever».
    @discardableResult
    public static func run(days: Int, in directory: URL, database: SusuDatabase, now: Date = Date()) throws -> Result {
        guard let cutoff = cutoff(days: days, now: now) else { return Result(clearedRows: 0, deletedFiles: 0) }
        return try purge(olderThan: cutoff, in: directory, database: database)
    }

    /// For every dictation, call and note created before `cutoff`: sets `audio_path` to NULL and deletes the file.
    /// Relative paths resolve against `directory`. A file that is already gone is not an error.
    @discardableResult
    public static func purge(olderThan cutoff: Date, in directory: URL, database: SusuDatabase) throws -> Result {
        let cut = SusuTime.string(cutoff)
        let targets: [(table: String, timeColumn: String)] = [
            ("dictation", "created_at"), ("call", "started_at"), ("note", "created_at"),
        ]
        var paths: [String] = []
        var rows = 0
        try database.writer.write { db in
            for t in targets {
                let found = try String.fetchAll(
                    db, sql: "SELECT audio_path FROM \(t.table) WHERE audio_path IS NOT NULL AND \(t.timeColumn) < ?",
                    arguments: [cut])
                try db.execute(
                    sql: "UPDATE \(t.table) SET audio_path = NULL WHERE audio_path IS NOT NULL AND \(t.timeColumn) < ?",
                    arguments: [cut])
                rows += found.count
                paths += found
            }
        }
        var deleted = 0
        for path in Set(paths) where removeFile(path, in: directory) { deleted += 1 }
        return Result(clearedRows: rows, deletedFiles: deleted)
    }

    private static func removeFile(_ path: String, in directory: URL) -> Bool {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}
