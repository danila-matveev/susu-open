import Foundation
import GRDB
import Testing
@testable import SusuCore

func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("susu-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct StoreTests {
    static let tables = ["dictation", "agent_request", "dictionary_entry", "style", "style_rule", "call",
                         "call_segment", "call_speaker", "task_item", "note", "memory_fact", "spend", "import_run"]

    @Test func migratesFromScratchInWAL() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sub/susu.sqlite")
        let db = try SusuDatabase(url: url)
        try db.writer.read { db in
            let names = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            for t in Self.tables { #expect(names.contains(t), "missing table \(t)") }
            #expect(try String.fetchOne(db, sql: "PRAGMA journal_mode") == "wal")
            #expect(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") == ["v1"])
        }
        // Reopening is a no-op migration.
        _ = try SusuDatabase(url: url)
    }

    @Test func everyTableHasUpdatedAtAndDeletedAt() throws {
        let db = try SusuDatabase.inMemory()
        try db.writer.read { db in
            for t in Self.tables {
                let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(\(t))").map { $0["name"] as String }
                #expect(cols.contains("updated_at"), "\(t) lacks updated_at")
                #expect(cols.contains("deleted_at"), "\(t) lacks deleted_at")
            }
        }
    }

    @Test func updatedAtTriggerBumpsOnEveryTable() throws {
        let db = try SusuDatabase.inMemory()
        let old = "2020-01-01T00:00:00.000Z"
        try db.writer.write { db in
            try db.execute(sql: "INSERT INTO dictation(id, created_at, status, updated_at) VALUES ('d1', ?, 'inserted', ?)", arguments: [old, old])
            try db.execute(sql: "INSERT INTO call(id, started_at, updated_at) VALUES ('c1', ?, ?)", arguments: [old, old])
            try db.execute(sql: "INSERT INTO call_speaker(call_id, speaker_key, updated_at) VALUES ('c1', 'mic', ?)", arguments: [old])
            try db.execute(sql: "UPDATE dictation SET raw_text = 'x' WHERE id = 'd1'")
            try db.execute(sql: "UPDATE call_speaker SET display_name = 'Dan' WHERE call_id = 'c1'")
            #expect(try String.fetchOne(db, sql: "SELECT updated_at FROM dictation WHERE id='d1'")! > old)
            #expect(try String.fetchOne(db, sql: "SELECT updated_at FROM call_speaker")! > old)
            #expect(try String.fetchOne(db, sql: "SELECT updated_at FROM call WHERE id='c1'") == old)
            // An explicit updated_at (what sync will do) is respected.
            let pinned = "2021-05-05T05:05:05.000Z"
            try db.execute(sql: "UPDATE dictation SET raw_text = 'y', updated_at = ? WHERE id = 'd1'", arguments: [pinned])
            #expect(try String.fetchOne(db, sql: "SELECT updated_at FROM dictation WHERE id='d1'") == pinned)
        }
    }

    @Test func sourceAndSourceIdAreUnique() throws {
        let db = try SusuDatabase.inMemory()
        try db.writer.write { db in
            try Dictation(id: "a", source: "wispr", sourceId: "w1").insert(db)
            try Dictation(id: "n1", source: "susu").insert(db)  // nil source_id: no uniqueness
            try Dictation(id: "n2", source: "susu").insert(db)
            #expect(throws: DatabaseError.self) { try Dictation(id: "b", source: "wispr", sourceId: "w1").insert(db) }
        }
    }

    @Test func recordsRoundTrip() throws {
        let db = try SusuDatabase.inMemory()
        let t = Date(timeIntervalSince1970: 1_800_000_000.123)
        try db.writer.write { db in
            try Spend(at: t, task: "editor", provider: "groq", tokensIn: 10, tokensOut: 5, costUsd: 0.001).insert(db)
            try DictionaryEntry(id: "e", phrase: "Susu", starred: true, createdAt: t).insert(db)
            try Style(id: "s", name: "Mail", isDefault: true).insert(db)
            try StyleRule(id: "r", styleId: "s", kind: "bundle", pattern: "com.apple.mail", priority: 3).insert(db)
            try Note(id: "n", createdAt: t, title: "Idea", text: "text").insert(db)
        }
        try db.writer.read { db in
            let s = try #require(try Spend.fetchOne(db))
            #expect(abs(s.at.timeIntervalSince(t)) < 0.0005 && SusuTime.string(s.at) == "2027-01-15T08:00:00.123Z" && s.tokensIn == 10 && s.costUsd == 0.001)
            #expect(try DictionaryEntry.fetchOne(db, key: "e")?.starred == true)
            #expect(try Style.fetchOne(db, key: "s")?.isDefault == true)
            #expect(try StyleRule.fetchOne(db, key: "r")?.priority == 3)
            #expect(try Note.fetchOne(db, key: "n").map { SusuTime.string($0.createdAt) } == "2027-01-15T08:00:00.123Z")
            #expect(try String.fetchOne(db, sql: "SELECT at FROM spend") == "2027-01-15T08:00:00.123Z")
        }
    }

    @Test func ftsFindsNotesAndCallSegments() throws {
        let db = try SusuDatabase.inMemory()
        try db.writer.write { db in
            try Note(id: "n", title: "Бюджет проекта", text: "обсудить расходы").insert(db)
            try db.execute(sql: "INSERT INTO call(id, started_at) VALUES ('c', '2026-01-01T00:00:00.000Z')")
            try db.execute(sql: "INSERT INTO call_segment(id, call_id, channel, start_ms, end_ms, text) VALUES ('s','c','mic',0,1,'договорились про дедлайн')")
            #expect(try String.fetchAll(db, sql: "SELECT n.id FROM note_fts JOIN note n ON n.rowid = note_fts.rowid WHERE note_fts MATCH 'бюдж*'") == ["n"])
            #expect(try String.fetchAll(db, sql: "SELECT s.id FROM call_segment_fts JOIN call_segment s ON s.rowid = call_segment_fts.rowid WHERE call_segment_fts MATCH 'ДЕДЛАЙН'") == ["s"])
            try db.execute(sql: "UPDATE note SET title = 'Другое' WHERE id = 'n'")
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM note_fts WHERE note_fts MATCH 'бюджет'") == 0)
        }
    }

    @Test func timeFormatRoundTripsAndMatchesSQLite() throws {
        let samples: [Double] = [0, 1.5, 951_782_400.999, 1_800_000_000.123, 4_102_444_800.001, -1.001]
        for s in samples {
            let d = Date(timeIntervalSince1970: s)
            let text = SusuTime.string(d)
            let back = try #require(SusuTime.date(text))
            #expect(abs(back.timeIntervalSince(d)) < 0.0006)
            #expect(SusuTime.string(back) == text)
        }
        let db = try SusuDatabase.inMemory()
        let sqlite = try db.writer.read { try String.fetchOne($0, sql: "SELECT strftime('%Y-%m-%dT%H:%M:%fZ', 1800000000.123, 'unixepoch')") }
        #expect(SusuTime.string(Date(timeIntervalSince1970: 1_800_000_000.123)) == sqlite)
        #expect(SusuTime.date("2026-11-13T09:05:01Z") != nil)
        #expect(SusuTime.date("garbage") == nil)
    }
}
