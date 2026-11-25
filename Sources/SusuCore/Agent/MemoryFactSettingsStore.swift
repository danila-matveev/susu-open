// «Обо мне» (spec 9.9): the short facts the agent always knows. Settings reads, edits and deletes them here.
// Lives in SusuCore because the database is a SusuCore detail (SusuApp does not link GRDB).
import Foundation
import GRDB

public struct MemoryFact: SusuRecord, Identifiable {
    public static let databaseTableName = "memory_fact"
    public var id: String
    public var text: String
    /// `manual` or `agent`
    public var origin: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: String = UUID().uuidString, text: String, origin: String = "manual",
                createdAt: Date = Date(), updatedAt: Date? = nil, deletedAt: Date? = nil) {
        self.id = id; self.text = text; self.origin = origin
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt; self.deletedAt = deletedAt
    }
}

public final class MemoryFactSettingsStore: Sendable {
    let database: SusuDatabase
    public init(database: SusuDatabase) { self.database = database }

    /// Oldest first.
    public func facts() async throws -> [MemoryFact] {
        try await database.writer.read { db in
            try MemoryFact.fetchAll(db, sql: "SELECT * FROM memory_fact WHERE deleted_at IS NULL ORDER BY created_at, id")
        }
    }

    @discardableResult
    public func add(_ text: String, origin: String = "manual", now: Date = Date()) async throws -> MemoryFact? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let fact = MemoryFact(text: t, origin: origin, createdAt: now)
        try await database.writer.write { db in try fact.insert(db) }
        return fact
    }

    /// Empty text deletes the fact.
    public func update(id: String, text: String, now: Date = Date()) async throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return try await delete(id: id, now: now) }
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE memory_fact SET text = ? WHERE id = ? AND deleted_at IS NULL", arguments: [t, id])
        }
    }

    public func delete(id: String, now: Date = Date()) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE memory_fact SET deleted_at = ? WHERE id = ?", arguments: [SusuTime.string(now), id])
        }
    }
}
