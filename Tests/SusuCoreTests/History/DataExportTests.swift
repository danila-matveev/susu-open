import Foundation
import GRDB
import Testing
@testable import SusuCore

@Suite struct DataExportTests {
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("susu-exp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    #if os(macOS)
    @Test func exportZipHasDatabaseAudioAndSettingsWithoutKeys() async throws {
        let dir = try tempDir()
        let out = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: out) }
        let services = try AppServices(directory: dir)
        try await services.history.save(Dictation(id: "d1", finalText: "hello export", audioPath: "audio/dictations/d1.m4a"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("audio/dictations"), withIntermediateDirectories: true)
        try Data(count: 64).write(to: dir.appendingPathComponent("audio/dictations/d1.m4a"))
        _ = try services.settings.update {
            $0.theme = .dark
            $0.unknownFields["apiKey"] = .string("sk-secret-should-not-leave")
            $0.unknownFields["future"] = .string("kept")
        }

        let zip = out.appendingPathComponent("Susu-export.zip")
        try DataExporter(directory: dir, database: services.database).export(to: zip)
        #expect(FileManager.default.fileExists(atPath: zip.path))

        let unpacked = out.appendingPathComponent("unpacked")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, unpacked.path]
        try p.run(); p.waitUntilExit()
        let root = unpacked.appendingPathComponent("Susu-export")

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("audio/dictations/d1.m4a").path))
        let settingsText = try String(contentsOf: root.appendingPathComponent("settings.json"), encoding: .utf8)
        #expect(settingsText.contains("dark") && settingsText.contains("kept"))
        #expect(!settingsText.contains("sk-secret-should-not-leave"))
        // The copied database opens and holds the row, and its search index still works.
        let copy = try DatabaseQueue(path: root.appendingPathComponent("susu.sqlite").path)
        let found = try await copy.read { try String.fetchAll($0, sql: "SELECT id FROM dictation WHERE rowid IN (SELECT rowid FROM dictation_fts WHERE dictation_fts MATCH 'hello')") }
        #expect(found == ["d1"])
    }
    #endif

    @Test func eraseAllEmptiesDataKeepsDefaultsUsable() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let services = try AppServices(directory: dir)
        try await services.styles.seedDefaultsIfEmpty()
        try await services.history.save(Dictation(id: "d1", finalText: "secret", audioPath: "audio/d1.m4a"))
        _ = try await MemoryFactSettingsStore(database: services.database).add("fact")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("audio"), withIntermediateDirectories: true)
        try Data(count: 8).write(to: dir.appendingPathComponent("audio/d1.m4a"))
        _ = try services.settings.update { $0.theme = .dark }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("recovery"), withIntermediateDirectories: true)
        try Data("{\"finalText\":\"secret\"}".utf8).write(to: dir.appendingPathComponent("recovery/d9.json"))

        try await DataEraser.eraseAll(in: dir, database: services.database, settings: services.settings)

        #expect(try await services.history.fetch(id: "d1") == nil)
        #expect(try await MemoryFactSettingsStore(database: services.database).facts().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("recovery").path))
        #expect(services.settings.current.theme == .system)
        #expect(try await services.styles.styles().count > 0)
    }

    @Test func memoryFactsAddEditDelete() async throws {
        let db = try SusuDatabase.inMemory()
        let store = MemoryFactSettingsStore(database: db)
        #expect(try await store.add("   ") == nil)
        let a = try #require(try await store.add("Anya is a designer", now: Date(timeIntervalSince1970: 1000)))
        let b = try #require(try await store.add("Igor is the fabric supplier", now: Date(timeIntervalSince1970: 2000)))
        #expect(try await store.facts().map(\.text) == ["Anya is a designer", "Igor is the fabric supplier"])
        try await store.update(id: a.id, text: "Anya designs the packaging")
        try await store.delete(id: b.id)
        #expect(try await store.facts().map(\.text) == ["Anya designs the packaging"])
        try await store.update(id: a.id, text: "  ")  // empty text removes
        #expect(try await store.facts().isEmpty)
    }

    @Test func settingsPreferencesRoundTripAndDefaults() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.current.preferences.agentTimeZone == "America/Sao_Paulo")
        #expect(Set(store.current.preferences.contextExclusions) == ContextRules.defaultExclusions)
        _ = try store.update {
            $0.preferences.workMode = .macOnly
            $0.preferences.jobFallbacks["editor"] = ProviderChoice(providerID: .openRouter, model: "x")
            $0.unknownFields["future"] = .bool(true)
        }
        let again = SettingsStore(directory: dir).current
        #expect(again.preferences.workMode == .macOnly)
        #expect(again.preferences.jobFallbacks["editor"]?.model == "x")
        #expect(again.unknownFields["future"] == .bool(true))
    }
}
