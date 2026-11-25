import Foundation
import GRDB

/// Styles and their "where to apply" rules in the local database (spec 5.2 `style`, `style_rule`).
public final class StyleStore: Sendable {
    let database: SusuDatabase
    public init(database: SusuDatabase) { self.database = database }
    private var writer: any DatabaseWriter { database.writer }

    /// Live styles in display order.
    public func styles() async throws -> [Style] {
        try await writer.read { db in
            try Style.fetchAll(db, sql: "SELECT * FROM style WHERE deleted_at IS NULL ORDER BY sort, id")
        }
    }

    /// Live rules of live styles; all of them, or the rules of one style.
    public func rules(styleId: String? = nil) async throws -> [StyleRule] {
        try await writer.read { db in
            try StyleRule.fetchAll(db, sql: """
                SELECT r.* FROM style_rule r JOIN style s ON s.id = r.style_id
                WHERE r.deleted_at IS NULL AND s.deleted_at IS NULL AND (? IS NULL OR r.style_id = ?)
                ORDER BY s.sort, r.priority DESC, r.id
                """, arguments: [styleId, styleId])
        }
    }

    /// Inserts or replaces. Making a style default clears the flag on the others.
    public func save(style: Style) async throws {
        try await writer.write { db in
            if style.isDefault {
                try db.execute(sql: "UPDATE style SET is_default = 0 WHERE is_default = 1 AND id <> ?", arguments: [style.id])
            }
            try style.save(db)
        }
    }

    public func save(rule: StyleRule) async throws {
        try await writer.write { try rule.save($0) }
    }

    /// Soft-deletes the style together with its rules.
    public func delete(styleId: String, now: Date = Date()) async throws {
        let ts = SusuTime.string(now)
        try await writer.write { db in
            try db.execute(sql: "UPDATE style SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL", arguments: [ts, styleId])
            try db.execute(sql: "UPDATE style_rule SET deleted_at = ? WHERE style_id = ? AND deleted_at IS NULL", arguments: [ts, styleId])
        }
    }

    public func delete(ruleId: String, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE style_rule SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL",
                           arguments: [SusuTime.string(now), ruleId])
        }
    }

    /// First launch: creates the five default styles of spec 3.5. Does nothing if the table has ever had rows
    /// (including deleted ones), so it is idempotent and never resurrects what the user removed.
    public func seedDefaultsIfEmpty() async throws {
        try await writer.write { db in
            guard try Style.fetchCount(db) == 0 else { return }
            let defaults = StyleDefaults.make()
            let now = Date()
            for var s in defaults.styles { s.updatedAt = now; try s.insert(db) }
            for var r in defaults.rules { r.updatedAt = now; try r.insert(db) }
        }
    }
}
