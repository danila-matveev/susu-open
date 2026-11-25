import Foundation
import GRDB

/// Where a dictionary import comes from. `rawValue` goes into `dictionary_entry.source` and `import_run.source`.
public enum DictionaryImportSource: String, Sendable, CaseIterable {
    /// «Словарь из файла»: any CSV / TXT / TSV / JSON list (Aqua Voice, MacWhisper, Spokenly exports, own lists).
    case file
    /// VoiceInk: its dictionary export or its Settings > Backup JSON.
    case voiceink
    /// Superwhisper: its app folder (`~/superwhisper`), read-only.
    case superwhisper
}

/// What a dictionary import found / did. Counts are per entry, not per file.
public struct DictionaryImportResult: Codable, Sendable, Equatable {
    public var source: String
    public var dryRun: Bool
    /// Items understood in the source.
    public var found = 0
    /// Of `imported`: how many words, replacements, snippets.
    public var words = 0
    public var replacements = 0
    public var snippets = 0
    /// Written now (dry run: would be written).
    public var imported = 0
    /// Already in Susu with the same kind and phrase (any origin) — left as they are.
    public var alreadyInSusu = 0
    /// Items looked at but not understood (empty, too long, disabled).
    public var skipped = 0
    /// Files read (Superwhisper reads several).
    public var files: [String] = []
    /// Russian notes for the report screen.
    public var notes: [String] = []
}

/// Adds words, replacements and snippets from other dictation apps to the Susu dictionary
/// (docs/research/imports-competitors.md, approved for 1.0 on 12.11.2026).
///
/// Safety, same as the Wispr import: source files are only read, never written. Re-running is safe:
/// an entry whose kind + phrase (case-insensitive, ё = е) is already in the dictionary is not added again,
/// whichever way it got there. Entries get `origin = import`, `source = <app>`, `source_id = <kind>:<phrase>`.
public final class DictionaryImporter: Sendable {
    public let database: SusuDatabase
    private let clock: @Sendable () -> Date

    public init(database: SusuDatabase, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.clock = clock
    }

    // MARK: Entry points

    /// One file picked by the user («Словарь из файла» or a VoiceInk export / backup).
    public func importFile(_ url: URL, source: DictionaryImportSource = .file, dryRun: Bool = false) async throws -> DictionaryImportResult {
        let parsed = try DictionaryFileParser.parse(fileURL: url)
        var result = DictionaryImportResult(source: source.rawValue, dryRun: dryRun)
        result.files = [url.lastPathComponent]
        result.notes = parsed.notes
        result.skipped = parsed.skipped
        if source == .voiceink {
            result.notes.append("режимы и промпты VoiceInk не переносим: их формат не описан, перенесены только словарь и замены")
        }
        return try await write(parsed.terms, into: result, source: source)
    }

    /// Superwhisper keeps vocabulary and replacements as JSON inside `<folder>/settings/`.
    /// The exact layout is not documented, so every JSON file there is read by shape.
    public func importSuperwhisper(folder: URL? = nil, dryRun: Bool = false) async throws -> DictionaryImportResult {
        var result = DictionaryImportResult(source: DictionaryImportSource.superwhisper.rawValue, dryRun: dryRun)
        guard let folder = folder ?? Self.defaultSuperwhisperFolder() else {
            result.notes.append("папка Superwhisper не найдена (~/superwhisper, ~/Documents/superwhisper)")
            return result
        }
        let settings = folder.appendingPathComponent("settings", isDirectory: true)
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: settings, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if files.isEmpty { result.notes.append("в папке settings нет JSON-файлов со словарём") }

        var terms: [ImportedTerm] = []
        for file in files {
            guard let data = try? Data(contentsOf: file), data.count <= DictionaryFileParser.maxBytes else {
                result.notes.append("\(file.lastPathComponent): не прочитан"); continue
            }
            let parsed = DictionaryFileParser.finish(DictionaryFileParser.parseJSON(data: data, rootMap: false))
            result.files.append(file.lastPathComponent)
            result.skipped += parsed.skipped
            terms += parsed.terms
            if parsed.terms.isEmpty { result.notes.append("\(file.lastPathComponent): словаря не нашлось") }
        }
        for (sub, what) in [("modes", "режимы"), ("recordings", "история и звук")] {
            if fm.fileExists(atPath: folder.appendingPathComponent(sub).path) {
                result.notes.append("\(what) Superwhisper пока не переносим: формат файлов не описан, сначала проверим на настоящей установке")
            }
        }
        return try await write(DictionaryFileParser.finish(.init(terms: terms)).terms, into: result, source: .superwhisper)
    }

    /// `~/superwhisper`, or `~/Documents/superwhisper` on older installs; nil when neither exists.
    public static func defaultSuperwhisperFolder(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL? {
        [home.appendingPathComponent("superwhisper", isDirectory: true),
         home.appendingPathComponent("Documents/superwhisper", isDirectory: true)]
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("settings").path) }
    }

    // MARK: Writing

    static func sourceId(_ t: ImportedTerm) -> String { t.kind + ":" + EditLearner.normalize(t.phrase) }

    private func write(_ terms: [ImportedTerm], into input: DictionaryImportResult,
                       source: DictionaryImportSource) async throws -> DictionaryImportResult {
        var result = input
        result.found = terms.count
        let now = clock()
        let dryRun = result.dryRun
        let start = result
        let final: DictionaryImportResult = try await database.writer.write { db in
            var r = start
            // SQLite lower() only handles ASCII, so keys are built in Swift (same as DictionaryService.add).
            var existing = Set(try DictionaryEntry.filter(sql: "deleted_at IS NULL").fetchAll(db)
                .map { $0.kind + ":" + EditLearner.normalize($0.phrase) })
            // A soft-deleted entry from an earlier import keeps its (source, source_id): never insert it twice.
            let taken = Set(try String.fetchAll(db, sql: "SELECT source_id FROM dictionary_entry WHERE source = ? AND source_id IS NOT NULL",
                                                arguments: [source.rawValue]))
            for t in terms {
                let key = Self.sourceId(t)
                if existing.contains(key) || taken.contains(key) { r.alreadyInSusu += 1; continue }
                existing.insert(key)
                r.imported += 1
                switch t.kind {
                case "snippet": r.snippets += 1
                case "replacement": r.replacements += 1
                default: r.words += 1
                }
                if dryRun { continue }
                try DictionaryEntry(kind: t.kind, phrase: t.phrase, replacement: t.replacement, origin: "import",
                                    createdAt: now, source: source.rawValue, sourceId: key).insert(db)
            }
            let json = String(data: try JSONEncoder().encode(r), encoding: .utf8)
            try ImportRun(at: now, source: source.rawValue, dryRun: dryRun, reportJson: json).insert(db)
            return r
        }
        return final
    }
}
