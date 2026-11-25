import Foundation
import GRDB

/// The app database (`susu.sqlite`, spec 5.1/5.2). Named `SusuDatabase` to avoid clashing with `GRDB.Database`.
public final class SusuDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// Opens (creating if needed) a WAL database at `url` and migrates it to the latest schema.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        writer = try DatabasePool(path: url.path, configuration: config)
        try Self.migrator.migrate(writer)
    }

    private init(inMemory: Void) throws {
        writer = try DatabaseQueue()
        try Self.migrator.migrate(writer)
    }

    /// In-memory database for tests that do not need WAL.
    public static func inMemory() throws -> SusuDatabase { try SusuDatabase(inMemory: ()) }

    /// Default location: `~/Library/Application Support/Susu/susu.sqlite`.
    public static func defaultURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Susu", isDirectory: true)
            .appendingPathComponent("susu.sqlite")
    }

    /// Schema changes go only through new migrations, each with its own test (spec 5.2).
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1", migrate: SchemaV1.migrate)
        return migrator
    }
}
