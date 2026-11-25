import Foundation
import GRDB
import Testing
@testable import SusuCore

@Suite struct RetentionTests {
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("susu-ret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func write(_ dir: URL, _ rel: String, bytes: Int = 10) throws {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    @Test func purgeClearsOldAudioAndKeepsNewAndText() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try SusuDatabase.inMemory()
        let store = HistoryStore(database: db, baseDirectory: dir)
        let now = SusuTime.date("2026-11-13T12:00:00.000Z")!
        let old = now.addingTimeInterval(-100 * 86_400)
        let fresh = now.addingTimeInterval(-5 * 86_400)
        try await store.save([
            Dictation(id: "old", createdAt: old, finalText: "old text", audioPath: "audio/dictations/old.m4a"),
            Dictation(id: "new", createdAt: fresh, finalText: "new text", audioPath: "audio/dictations/new.m4a"),
            Dictation(id: "abs", createdAt: old, finalText: "abs", audioPath: dir.appendingPathComponent("elsewhere.m4a").path),
            Dictation(id: "gone", createdAt: old, finalText: "gone", audioPath: "audio/dictations/missing.m4a"),
        ])
        try write(dir, "audio/dictations/old.m4a")
        try write(dir, "audio/dictations/new.m4a")
        try write(dir, "elsewhere.m4a")

        let result = try AudioRetention.run(days: 90, in: dir, database: db, now: now)

        #expect(result.clearedRows == 3)
        #expect(result.deletedFiles == 2)  // the missing file is cleared in the table but is not counted
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("audio/dictations/old.m4a").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("elsewhere.m4a").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("audio/dictations/new.m4a").path))
        let oldRow = try #require(try await store.fetch(id: "old"))
        #expect(oldRow.audioPath == nil && oldRow.finalText == "old text")
        #expect(try await store.fetch(id: "new")?.audioPath == "audio/dictations/new.m4a")
    }

    @Test func foreverDoesNothingAndCutoffMath() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try SusuDatabase.inMemory()
        let store = HistoryStore(database: db, baseDirectory: dir)
        try await store.save(Dictation(id: "a", createdAt: Date(timeIntervalSince1970: 0), audioPath: "audio/a.m4a"))
        try write(dir, "audio/a.m4a")

        let r = try AudioRetention.run(days: AudioRetention.forever, in: dir, database: db)
        #expect(r == .init(clearedRows: 0, deletedFiles: 0))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio/a.m4a").path))
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(AudioRetention.cutoff(days: 14, now: now) == now.addingTimeInterval(-14 * 86_400))
        #expect(AudioRetention.cutoff(days: 0, now: now) == nil)
    }

    @Test func purgeCoversCallsAndNotes() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try SusuDatabase.inMemory()
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO call (id, started_at, audio_path) VALUES ('c1', '2020-01-01T00:00:00.000Z', 'calls/c1/audio.m4a')")
            try db.execute(sql: "INSERT INTO note (id, created_at, audio_path) VALUES ('n1', '2020-01-01T00:00:00.000Z', 'audio/notes/n1.m4a')")
        }
        try write(dir, "calls/c1/audio.m4a")
        try write(dir, "audio/notes/n1.m4a")
        let r = try AudioRetention.purge(olderThan: Date(), in: dir, database: db)
        #expect(r.clearedRows == 2 && r.deletedFiles == 2)
        let left = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM call WHERE audio_path IS NOT NULL") }
        #expect(left == 0)
    }

    @Test func usageCountsByType() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(dir, "audio/dictations/a.m4a", bytes: 100)
        try write(dir, "audio/notes/b.m4a", bytes: 50)
        try write(dir, "calls/c/audio.m4a", bytes: 1000)
        try write(dir, "models/m.bin", bytes: 7)
        try write(dir, "susu.sqlite", bytes: 20)
        try write(dir, "susu.sqlite-wal", bytes: 5)
        let u = DataUsage.measure(in: dir)
        #expect(u.dictationAudio == 150 && u.callAudio == 1000 && u.models == 7 && u.database == 25)
        #expect(u.total == 1182)
    }
}
