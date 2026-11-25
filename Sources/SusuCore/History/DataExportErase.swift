// «Удалить всё» (spec 1.6): history, audio, notes, dictionary and settings. API keys stay in the Keychain
// (the user removes them in Models). The caller asks for a typed-word confirmation first.
import Foundation
import GRDB

public enum DataEraser {
    /// Tables in an order that respects foreign keys (children first).
    static let tables = [
        "call_segment", "call_speaker", "task_item", "agent_request", "call", "dictation", "note",
        "dictionary_entry", "style_rule", "style", "memory_fact", "spend", "import_run",
    ]

    /// Empties every table, deletes recordings and imports, resets settings to defaults,
    /// then puts the default styles back so the app stays usable.
    public static func eraseAll(in directory: URL, database: SusuDatabase, settings: SettingsStore) async throws {
        try await database.writer.write { db in
            for t in tables { try db.execute(sql: "DELETE FROM \(t)") }
        }
        let fm = FileManager.default
        // "recovery" holds dictation text that the database refused; it is user data like the rest.
        for folder in ["audio", "calls", "import", "recovery"] {
            let url = directory.appendingPathComponent(folder)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        _ = try settings.update { $0 = Settings() }
        try await StyleStore(database: database).seedDefaultsIfEmpty()
    }
}
