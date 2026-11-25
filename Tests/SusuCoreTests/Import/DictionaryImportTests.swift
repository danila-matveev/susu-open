import Foundation
import GRDB
import Testing
@testable import SusuCore

/// «Словарь из файла», VoiceInk and Superwhisper dictionary import. All inputs are synthetic and built here:
/// the real formats of those apps are not documented, so the parser is tested on the shapes they are known to use.
@Suite struct DictionaryFileParserTests {
    private func parse(_ text: String, _ ext: String) -> DictionaryFileParser.Result {
        DictionaryFileParser.parse(data: Data(text.utf8), fileExtension: ext)
    }

    // MARK: Plain text

    @Test func plainTextWordsAndArrows() {
        let r = parse("""
        # my words
        SpeechKit
        Groq

        клод -> Claude
        жира → Jira
        """, "txt")
        #expect(r.terms == [.word("SpeechKit"), .word("Groq"), .replacement("клод", "Claude"), .replacement("жира", "Jira")])
    }

    @Test func plainTextTabSeparated() {
        let r = parse("теле мост\tТелемост\nBitrix24\n", "txt")
        #expect(r.terms == [.replacement("теле мост", "Телемост"), .word("Bitrix24")])
    }

    @Test func duplicatesInsideFileKeepFirstAndNote() {
        let r = parse("Groq\ngroq\nGROQ\nClaude\n", "txt")
        #expect(r.terms == [.word("Groq"), .word("Claude")])
        #expect(r.notes.contains { $0.contains("повторы") })
    }

    @Test func yoAndCaseCountAsSamePhrase() {
        let r = parse("ёлка\nЕЛКА\n", "txt")
        #expect(r.terms.count == 1)
    }

    @Test func tooLongPhraseIsSkipped() {
        let r = parse(String(repeating: "a", count: 300) + "\nok\n", "txt")
        #expect(r.terms == [.word("ok")])
        #expect(r.skipped == 1)
    }

    // MARK: CSV / TSV

    @Test func csvOneColumnNoHeader() {
        #expect(parse("SpeechKit\nGroq\n", "csv").terms == [.word("SpeechKit"), .word("Groq")])
    }

    @Test func csvTwoColumnsNoHeaderLikeWisprBulkFormat() {
        // Wispr's documented bulk format: one column = word, two columns = misspelling,correction.
        let r = parse("Groq\nяндекс печкин,SpeechKit\n", "csv")
        #expect(r.terms == [.word("Groq"), .replacement("яндекс печкин", "SpeechKit")])
    }

    @Test func csvWithHeaderInAnyOrder() {
        let r = parse("replacement,original\nClaude,клод\nJira,жира\n", "csv")
        #expect(r.terms == [.replacement("клод", "Claude"), .replacement("жира", "Jira")])
    }

    @Test func csvQuotedCellsWithCommasAndQuotes() {
        let r = parse("word,replacement\n\"Hello, world\",\"Say \"\"hi\"\"\"\n", "csv")
        #expect(r.terms == [.replacement("Hello, world", "Say \"hi\"")])
    }

    @Test func csvSemicolonAndBOM() {
        let r = parse("\u{FEFF}слово;замена\nклод;Claude\n", "csv")
        #expect(r.terms == [.replacement("клод", "Claude")])
    }

    @Test func csvCRLFLineEndings() {
        #expect(parse("Groq\r\nClaude\r\n", "csv").terms == [.word("Groq"), .word("Claude")])
    }

    @Test func tsvWithHeader() {
        let r = parse("from\tto\nкодекс\tCodex\n", "tsv")
        #expect(r.terms == [.replacement("кодекс", "Codex")])
    }

    @Test func sameValueInBothColumnsIsAWord() {
        #expect(parse("Groq,Groq\n", "csv").terms == [.word("Groq")])
    }

    // MARK: JSON

    @Test func jsonArrayOfStrings() {
        #expect(parse(#"["SpeechKit", "Groq", ""]"#, "json").terms == [.word("SpeechKit"), .word("Groq")])
    }

    @Test func jsonArrayOfObjects() {
        let r = parse(#"[{"word": "Groq"}, {"original": "клод", "replacement": "Claude"}, {"from": "жира", "to": "Jira"}]"#, "json")
        #expect(r.terms == [.word("Groq"), .replacement("клод", "Claude"), .replacement("жира", "Jira")])
    }

    @Test func jsonRootFlatMapIsReplacements() {
        let r = parse(#"{"клод": "Claude", "жира": "Jira"}"#, "json")
        #expect(Set(r.terms) == [.replacement("клод", "Claude"), .replacement("жира", "Jira")])
    }

    @Test func jsonContainersLikeABackup() {
        // A backup-shaped file: settings next to the dictionary; only the dictionary parts are read.
        let json = #"""
        {
          "version": 3,
          "general": {"theme": "dark", "language": "ru"},
          "modes": [{"name": "Email", "prompt": "Be formal"}],
          "dictionary": {
            "vocabulary": ["SpeechKit", {"word": "Groq"}],
            "wordReplacements": {"клод": "Claude"}
          },
          "snippets": [{"trigger": "мой адрес", "text": "Москва, ул. Пушкина"}]
        }
        """#
        let r = parse(json, "json")
        #expect(Set(r.terms) == [.word("SpeechKit"), .word("Groq"), .replacement("клод", "Claude"),
                                 .snippet("мой адрес", "Москва, ул. Пушкина")])
    }

    @Test func jsonDisabledItemsAreSkipped() {
        let r = parse(#"{"replacements": [{"original": "a", "replacement": "b", "isEnabled": false}, {"original": "c", "replacement": "d"}]}"#, "json")
        #expect(r.terms == [.replacement("c", "d")])
        #expect(r.skipped == 1)
    }

    @Test func jsonWithoutDictionaryGivesANote() {
        let r = parse(#"{"general": {"theme": "dark"}, "count": 3}"#, "json")
        #expect(r.terms.isEmpty)
        #expect(!r.notes.isEmpty)
    }

    @Test func brokenJSONGivesANoteNotACrash() {
        let r = parse(#"{"vocabulary": ["#, "json")
        #expect(r.terms.isEmpty)
        #expect(r.notes == ["файл не читается как JSON"])
    }

    @Test func jsonDetectedWithoutExtension() {
        #expect(parse(#"["Groq"]"#, "").terms == [.word("Groq")])
    }

    @Test func cp1251TextIsRead() {
        let data = "Телемост\n".data(using: .windowsCP1251)!
        #expect(DictionaryFileParser.parse(data: data, fileExtension: "txt").terms == [.word("Телемост")])
    }
}

@Suite struct DictionaryImporterTests {
    private struct Env {
        let dir: URL
        let db: SusuDatabase
        let importer: DictionaryImporter
        init() throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("susu-dict-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            db = try SusuDatabase.inMemory()
            importer = DictionaryImporter(database: db)
        }
        func file(_ name: String, _ text: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return url
        }
        func entries() throws -> [DictionaryEntry] {
            try db.writer.read { try DictionaryEntry.filter(sql: "deleted_at IS NULL").order(sql: "phrase").fetchAll($0) }
        }
        func fingerprint(_ url: URL) throws -> [String] {
            let fm = FileManager.default
            let files = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])!
                .compactMap { $0 as? URL }.sorted { $0.path < $1.path }
            return try files.map { f in
                let v = try f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return "\(f.lastPathComponent)|\(v.fileSize ?? -1)|\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            }
        }
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    @Test func fileImportWritesEntriesWithOriginAndSource() async throws {
        let e = try Env(); defer { e.cleanup() }
        let url = try e.file("words.csv", "Groq\nклод,Claude\n")
        let r = try await e.importer.importFile(url)
        #expect(r.imported == 2 && r.words == 1 && r.replacements == 1)
        let rows = try e.entries()
        #expect(rows.map(\.phrase) == ["Groq", "клод"])
        #expect(rows.allSatisfy { $0.origin == "import" && $0.source == "file" })
        #expect(rows.first { $0.phrase == "клод" }?.replacement == "Claude")
        let runs = try await e.db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM import_run WHERE source = 'file'")! }
        #expect(runs == 1)
    }

    @Test func rerunAddsNothing() async throws {
        let e = try Env(); defer { e.cleanup() }
        let url = try e.file("words.txt", "Groq\nClaude\n")
        _ = try await e.importer.importFile(url)
        let second = try await e.importer.importFile(url)
        #expect(second.imported == 0 && second.alreadyInSusu == 2)
        #expect(try e.entries().count == 2)
    }

    @Test func existingManualEntryIsNotDuplicatedOrChanged() async throws {
        let e = try Env(); defer { e.cleanup() }
        let manual = try await DictionaryService(database: e.db).add(phrase: "ГРОК")
        let url = try e.file("words.txt", "грок\nClaude\n")
        let r = try await e.importer.importFile(url)
        #expect(r.imported == 1 && r.alreadyInSusu == 1)
        let rows = try e.entries()
        #expect(rows.count == 2)
        #expect(rows.first { $0.id == manual.id }?.origin == "manual")
    }

    @Test func entryDeletedAfterImportIsNotBroughtBack() async throws {
        let e = try Env(); defer { e.cleanup() }
        let url = try e.file("words.txt", "Groq\n")
        _ = try await e.importer.importFile(url)
        let id = try e.entries()[0].id
        try await DictionaryService(database: e.db).softDelete(id: id)
        let r = try await e.importer.importFile(url)
        #expect(r.imported == 0)
        #expect(try e.entries().isEmpty)
    }

    @Test func dryRunWritesOnlyTheReport() async throws {
        let e = try Env(); defer { e.cleanup() }
        let url = try e.file("words.txt", "Groq\nClaude\n")
        let r = try await e.importer.importFile(url, dryRun: true)
        #expect(r.imported == 2 && r.dryRun)
        #expect(try e.entries().isEmpty)
        let runs = try await e.db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM import_run WHERE dry_run = 1")! }
        #expect(runs == 1)
    }

    @Test func voiceInkBackupImportsDictionaryAndSaysModesAreNot() async throws {
        let e = try Env(); defer { e.cleanup() }
        let url = try e.file("VoiceInk-backup.json", #"""
        {"customPrompts": [{"title": "Email", "promptText": "Formal"}],
         "dictionaryItems": [{"word": "Groq"}, {"word": "SpeechKit"}],
         "wordReplacements": {"клод": "Claude"}}
        """#)
        let before = try e.fingerprint(e.dir)
        let r = try await e.importer.importFile(url, source: .voiceink)
        #expect(r.imported == 3 && r.source == "voiceink")
        #expect(r.notes.contains { $0.contains("VoiceInk") })
        #expect(try e.entries().allSatisfy { $0.source == "voiceink" })
        #expect(try e.fingerprint(e.dir) == before, "the source file must not change")
    }

    @Test func superwhisperFolderIsReadOnlyAndSettingsAreNotWords() async throws {
        let e = try Env(); defer { e.cleanup() }
        let folder = e.dir.appendingPathComponent("superwhisper")
        _ = try e.file("superwhisper/settings/settings.json", #"""
        {"theme": "dark", "hotkey": "fn",
         "vocabulary": ["Groq", "Телемост"],
         "replacements": [{"original": "клод", "replacement": "Claude"}]}
        """#)
        _ = try e.file("superwhisper/settings/ui.json", #"{"window": "compact", "sound": "on"}"#)
        _ = try e.file("superwhisper/modes/email.json", #"{"name": "Email"}"#)
        _ = try e.file("superwhisper/recordings/1/meta.json", #"{"result": "hi"}"#)
        let before = try e.fingerprint(folder)

        let r = try await e.importer.importSuperwhisper(folder: folder)
        #expect(r.imported == 3, "theme/hotkey/window/sound must not become dictionary entries")
        #expect(Set(try e.entries().map(\.phrase)) == ["Groq", "Телемост", "клод"])
        #expect(r.files == ["settings.json", "ui.json"])
        #expect(r.notes.contains { $0.contains("режимы") } && r.notes.contains { $0.contains("история") })
        #expect(try e.fingerprint(folder) == before, "Superwhisper folder must not change")
    }

    @Test func superwhisperMissingFolderGivesANote() async throws {
        let e = try Env(); defer { e.cleanup() }
        let r = try await e.importer.importSuperwhisper(folder: e.dir.appendingPathComponent("nope"))
        #expect(r.imported == 0)
        #expect(r.notes.contains { $0.contains("settings") })
    }

    @Test func defaultSuperwhisperFolderPrefersHomeThenDocuments() throws {
        let e = try Env(); defer { e.cleanup() }
        #expect(DictionaryImporter.defaultSuperwhisperFolder(home: e.dir) == nil)
        _ = try e.file("Documents/superwhisper/settings/s.json", "{}")
        #expect(DictionaryImporter.defaultSuperwhisperFolder(home: e.dir)?.path.hasSuffix("Documents/superwhisper") == true)
        _ = try e.file("superwhisper/settings/s.json", "{}")
        #expect(DictionaryImporter.defaultSuperwhisperFolder(home: e.dir)?.lastPathComponent == "superwhisper")
        #expect(DictionaryImporter.defaultSuperwhisperFolder(home: e.dir)?.path.contains("Documents") == false)
    }
}
