import AVFoundation
import Foundation
import GRDB
import Testing
@testable import SusuCore

private struct Env {
    let dir: URL
    let wispr: URL
    let data: URL
    let db: SusuDatabase
    let importer: WisprImporter

    init(_ variant: WisprFixture.Variant = .current, styles: Bool = true, bulk: Int = 0) throws {
        dir = try WisprFixture.tempDir()
        wispr = try WisprFixture.make(variant, in: dir, extraHistoryRows: bulk)
        data = dir.appendingPathComponent("susu-data")
        db = try SusuDatabase.inMemory()
        if styles { try WisprFixture.seedStyles(db) }
        importer = WisprImporter(database: db, dataDirectory: data, wisprFolder: wispr)
    }
    func read<T>(_ body: (Database) throws -> T) throws -> T { try db.writer.read(body) }
    func write<T>(_ body: (Database) throws -> T) throws -> T { try db.writer.write(body) }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
    func count(_ table: String, _ whereSQL: String = "1") throws -> Int {
        try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table) WHERE \(whereSQL)")! }
    }
    func dictation(_ sourceId: String) throws -> Dictation {
        try db.writer.read { try Dictation.filter(sql: "source = 'wispr' AND source_id = ?", arguments: [sourceId]).fetchOne($0)! }
    }
}

@Suite struct WisprImporterTests {
    // MARK: И1 — read-only

    @Test func i1_wisprFilesUntouchedByDryRunAndRun() async throws {
        let e = try Env(); defer { e.cleanup() }
        let before = try WisprFixture.fingerprint(e.wispr)
        _ = try await e.importer.dryRun()
        #expect(try WisprFixture.fingerprint(e.wispr) == before)
        _ = try await e.importer.run()
        #expect(try WisprFixture.fingerprint(e.wispr) == before, "size/mtime/file list of the Wispr folder must not change")
    }

    @Test func snapshotIsDeletedAfterImportAndDryRunWritesNothingButReport() async throws {
        let e = try Env(); defer { e.cleanup() }
        let dry = try await e.importer.dryRun()
        #expect(dry.dryRun)
        #expect(try e.count("dictation") == 0 && e.count("note") == 0 && e.count("call") == 0
                && e.count("dictionary_entry") == 0 && e.count("style_rule") == 0)
        #expect(try e.count("import_run", "dry_run = 1") == 1)
        let importDir = e.data.appendingPathComponent("import")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: importDir.path))?.isEmpty ?? true)

        _ = try await e.importer.run()
        #expect(try e.count("import_run", "dry_run = 0") == 1)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: importDir.path))?.isEmpty ?? true,
                "snapshot and checkpoint are removed after import")
    }

    @Test func snapshotIsAFaithfulCopy() throws {
        let dir = try WisprFixture.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wispr = try WisprFixture.make(in: dir)
        let snap = dir.appendingPathComponent("import/snap.sqlite")
        try WisprSnapshot.make(from: wispr.appendingPathComponent("flow.sqlite"), to: snap)
        let src = try DatabaseQueue(path: snap.path)
        #expect(try src.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM History") } == 12)
    }

    @Test func snapshotOfLiveWALDatabaseKeepsUncheckpointedRowsAndLeavesSourceAlone() async throws {
        let dir = try WisprFixture.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wispr = try WisprFixture.make(in: dir)
        let path = wispr.appendingPathComponent("flow.sqlite").path
        // Like running Wispr: WAL mode, a connection stays open, recent rows live only in the -wal file.
        var config = Configuration()
        config.prepareDatabase { try $0.execute(sql: "PRAGMA wal_autocheckpoint = 0") }
        let live = try DatabaseQueue(path: path, configuration: config)
        try Self.exec(live, "PRAGMA journal_mode = WAL")
        try Self.exec(live, "INSERT INTO Notes VALUES ('n9','Live','p','Only in WAL','2026-07-01 08:00:00.000 +00:00','2026-07-01 08:00:00.000 +00:00',0)")
        #expect(FileManager.default.fileExists(atPath: path + "-wal"))
        let before = try WisprFixture.fingerprint(wispr).filter { !$0.key.hasSuffix("-shm") }

        let data = dir.appendingPathComponent("susu-data")
        let db = try SusuDatabase.inMemory()
        let report = try await WisprImporter(database: db, dataDirectory: data, wisprFolder: wispr).run(includeAudio: false)
        #expect(report.step("Notes")?.total == 4)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: data.appendingPathComponent("import").path))?.isEmpty ?? true,
                "no stray -shm/-wal files of the snapshot")
        #expect(try WisprFixture.fingerprint(wispr).filter { !$0.key.hasSuffix("-shm") } == before)
        withExtendedLifetime(live) {}
    }

    private static func exec(_ q: DatabaseQueue, _ sql: String) throws {
        try q.writeWithoutTransaction { try $0.execute(sql: sql) }
    }

    @Test func missingSourceThrows() async throws {
        let dir = try WisprFixture.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let importer = WisprImporter(database: try .inMemory(), dataDirectory: dir.appendingPathComponent("d"),
                                     wisprFolder: dir.appendingPathComponent("nothing"))
        await #expect(throws: WisprError.self) { _ = try await importer.dryRun() }
    }

    // MARK: И2 — completeness and mapping

    @Test func i2_allHistoryRowsImportedWithMapping() async throws {
        let e = try Env(); defer { e.cleanup() }
        let report = try await e.importer.run(includeAudio: false)
        #expect(try e.count("dictation", "source = 'wispr'") == 12)
        let step = try #require(report.step("History"))
        #expect(step.total == 12 && step.imported == 12 && step.skipped == 0)

        let d1 = try e.dictation("h01")
        #expect(d1.finalText == "pasted one" && d1.rawText == "raw one" && d1.editedText == "edited one")
        #expect(d1.bundleId == "com.microsoft.VSCode" && d1.mode == .hold && d1.kind == .dictation && d1.status == .imported)
        #expect(d1.latencyMs == 905 && d1.durationMs == 3500)
        #expect(d1.createdAt == SusuTime.date("2026-08-04T09:48:11.864Z"))
        #expect(d1.source == "wispr" && d1.sourceId == "h01")

        let d2 = try e.dictation("h02")
        #expect(d2.finalText == "formatted two" && d2.mode == .handsfree)
        let d3 = try e.dictation("h03")
        #expect(d3.finalText == "raw three only" && d3.kind == .agent && d3.mode == nil && d3.status == .failed)
        #expect(try e.dictation("h04").status == .archived)
        let d5 = try e.dictation("h05")
        #expect(d5.latencyMs == nil, "clock-sized latency values are dropped")
        #expect(report.notes.contains { $0.contains("нет времени") })
    }

    @Test func pagingOverMoreThanOneBatch() async throws {
        let e = try Env(bulk: 1300); defer { e.cleanup() }
        _ = try await e.importer.run(includeAudio: false)
        #expect(try e.count("dictation") == 1312)
    }

    // MARK: И3 — audio

    @Test func i3_audioConvertedToM4AAndIdempotent() async throws {
        let e = try Env(); defer { e.cleanup() }
        let report = try await e.importer.run()
        let step = try #require(report.step("Audio"))
        #expect(step.total == 2 && step.imported == 2 && step.skipped == 0)
        let d = try e.dictation("h01")
        let path = try #require(d.audioPath)
        #expect(path.hasPrefix("audio/dictations/2026/08/") && path.hasSuffix("\(d.id).m4a"))
        let file = try AVAudioFile(forReading: e.data.appendingPathComponent(path))
        #expect(file.length > 0 && abs(file.processingFormat.sampleRate - 16_000) < 1)
        #expect(try e.count("dictation", "audio_path IS NOT NULL") == 2)
        let mtime = try FileManager.default.attributesOfItem(atPath: e.data.appendingPathComponent(path).path)[.modificationDate] as? Date
        let again = try await e.importer.run()
        #expect(again.step("Audio")?.imported == 0)
        #expect(try FileManager.default.attributesOfItem(atPath: e.data.appendingPathComponent(path).path)[.modificationDate] as? Date == mtime)
    }

    // MARK: И4 — dictionary

    @Test func i4_dictionaryEntriesAndSnippets() async throws {
        let e = try Env(); defer { e.cleanup() }
        let report = try await e.importer.run(includeAudio: false)
        let step = try #require(report.step("Dictionary"))
        #expect(step.total == 4 && step.imported == 3 && step.skipped == 1 && step.skipReasons["удалено в Wispr"] == 1)
        let entries = try e.read { try DictionaryEntry.order(sql: "source_id").fetchAll($0) }
        #expect(entries.map(\.sourceId) == ["d1", "d2", "d3"])
        #expect(entries.allSatisfy { $0.origin == "wispr" && $0.source == "wispr" })
        #expect(entries[0].kind == "word" && entries[0].starred && entries[0].useCount == 4)
        #expect(entries[1].kind == "replacement" && entries[1].replacement == "Lumera")
        #expect(entries[2].kind == "snippet" && entries[2].replacement == "ул. Тестовая, 1")
    }

    // MARK: И5 — styles

    @Test func i5_styleRulesFollowMostFrequentGroup() async throws {
        let e = try Env(); defer { e.cleanup() }
        let report = try await e.importer.run(includeAudio: false)
        let rules: [String: String] = try e.read { db in
            var map: [String: String] = [:]
            for r in try StyleRule.fetchAll(db) {
                map[r.pattern] = try String.fetchOne(db, sql: "SELECT name FROM style WHERE id = ?", arguments: [r.styleId])
            }
            return map
        }
        #expect(rules["com.microsoft.VSCode"] == "Код")            // work (2) beats other (1); code program
        #expect(rules["ru.keepcoder.Telegram"] == "Мессенджеры")   // personal (3) beats work (1)
        #expect(rules["com.apple.mail"] == "Почта")
        #expect(rules["com.apple.Safari"] == "Прочее")
        #expect(rules["com.tinyspeck.slackmacgap"] == "Мессенджеры") // work, not a code program
        #expect(rules["com.unknown.app"] == nil)                     // only `unset`
        let step = try #require(report.step("Styles"))
        #expect(step.imported == 5 && step.skipReasons["у программы нет группы Wispr"] == 1)
        #expect(report.suggestions.styleGroups["work"] == "casual")
    }

    @Test func styleRulesSkippedWhenStylesAreMissingAndNeverOverrideExistingRules() async throws {
        let e = try Env(styles: false); defer { e.cleanup() }
        let r1 = try await e.importer.run(includeAudio: false)
        #expect(try e.count("style_rule") == 0)
        #expect(r1.step("Styles")?.skipReasons.keys.contains { $0.contains("не найден") } == true)

        try WisprFixture.seedStyles(e.db)
        let styleId = try e.read { try String.fetchOne($0, sql: "SELECT id FROM style WHERE name = 'Почта'")! }
        try e.write { try StyleRule(styleId: styleId, kind: "bundle", pattern: "ru.keepcoder.Telegram").insert($0) }
        _ = try await e.importer.run(includeAudio: false)
        let tg = try e.read { try StyleRule.filter(sql: "pattern = 'ru.keepcoder.Telegram'").fetchAll($0) }
        #expect(tg.count == 1 && tg[0].styleId == styleId, "the user's own rule wins")
    }

    // MARK: И6 — no duplicates

    @Test func i6_secondRunCreatesNoDuplicates() async throws {
        let e = try Env(); defer { e.cleanup() }
        _ = try await e.importer.run()
        let tables = ["dictation", "dictionary_entry", "style_rule", "note", "call", "call_segment", "call_speaker"]
        let first = try tables.map { try e.count($0) }
        let second = try await e.importer.run()
        #expect(try tables.map { try e.count($0) } == first)
        for s in second.steps { #expect(s.imported == 0, "\(s.name) imported again") }
        #expect(second.step("History")?.alreadyImported == 12)
        #expect(try e.count("import_run") == 2)
    }

    // MARK: И7 — other schema

    @Test func i7_withoutPastedTextAndAudio() async throws {
        let e = try Env(.noPastedTextNoAudio); defer { e.cleanup() }
        let report = try await e.importer.run()
        #expect(try e.count("dictation") == 12)
        #expect(Set(report.missingColumns["History"] ?? []) == ["pastedText", "audio"])
        #expect(report.notes.contains("не найдено: History.pastedText") && report.notes.contains("не найдено: History.audio"))
        #expect(try e.dictation("h01").finalText == "formatted one")
        #expect(report.step("Audio")?.total == 0)
    }

    @Test func i7_withoutDictionaryTable() async throws {
        let e = try Env(.noDictionary); defer { e.cleanup() }
        let report = try await e.importer.run(includeAudio: false)
        #expect(try e.count("dictionary_entry") == 0 && e.count("dictation") == 12)
        let step = try #require(report.step("Dictionary"))
        #expect(step.note?.contains("Dictionary") == true && step.imported == 0)
        #expect(report.notes.contains { $0.contains("таблица Dictionary не найдена") })
    }

    @Test func i7_extraUnknownColumns() async throws {
        let e = try Env(.extraColumns); defer { e.cleanup() }
        let report = try await e.importer.run(includeAudio: false)
        #expect(try e.count("dictation") == 12 && e.count("dictionary_entry") == 3)
        #expect(report.missingColumns.isEmpty)
    }

    // MARK: Notes, meetings, config

    @Test func notesImported() async throws {
        let e = try Env(); defer { e.cleanup() }
        let report = try await e.importer.run(includeAudio: false)
        #expect(report.step("Notes")?.total == 3 && report.step("Notes")?.imported == 2)
        let notes = try e.read { try Note.order(sql: "source_id").fetchAll($0) }
        #expect(notes.map(\.title) == ["Plan", "Second"])
        #expect(notes[0].text == "Note body one" && notes[0].origin == "wispr" && notes[0].source == "wispr")
        #expect(try e.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_fts WHERE note_fts MATCH 'one'") } == 1)
    }

    @Test func meetingsImportedWithSegmentsSpeakersSummaryAndAudio() async throws {
        let e = try Env(); defer { e.cleanup() }
        let report = try await e.importer.run(includeAudio: false)
        let step = try #require(report.step("Meetings"))
        #expect(step.total == 3 && step.imported == 2 && step.skipReasons["удалено в Wispr"] == 1)
        #expect(step.details["фраз"] == 2 && step.details["звук_ogg"] == 1)

        let call = try e.read { try ImportedCall.filter(sql: "source_id = ?", arguments: [WisprFixture.meetingId]).fetchOne($0)! }
        #expect(call.title == "Planning" && call.status == "ready" && call.notes == "my notes" && call.calendarEventId == "cal-1")
        #expect(call.startedAt == SusuTime.date("2026-08-04T09:00:00.000Z"))
        #expect(call.endedAt == Date(timeIntervalSince1970: 1_785_837_000))
        #expect(call.participantsJson == #"[{"name":"Anna"},{"name":"Boris"}]"#)
        let summary = try #require(call.summaryJson)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(summary.utf8)) as? [String: Any])
        #expect(obj["markdown"] as? String == "# Summary\n- decided things" && (obj["tasks"] as? [Any])?.isEmpty == true)

        let segs = try e.read { try ImportedCallSegment.filter(sql: "call_id = ?", arguments: [call.id]).order(sql: "start_ms").fetchAll($0) }
        #expect(segs.map(\.text) == ["Hello everyone", "Hi, ready to start"], "refined wins over live; junk lines and empty text are ignored")
        #expect(segs.map(\.channel) == ["mic", "system"] && segs.allSatisfy { $0.pass == "final" })
        #expect(segs[0].startMs == 5000 && segs[0].endMs == 9500 && segs[1].startMs == 9500)
        #expect(segs.map(\.speakerKey) == ["mic:1", "system:2"])
        let speakers = try e.read { try ImportedCallSpeaker.filter(sql: "call_id = ?", arguments: [call.id]).order(sql: "speaker_key").fetchAll($0) }
        #expect(speakers.map(\.speakerKey) == ["mic:1", "system:2"] && speakers.map(\.displayName) == ["Me Myself", "Anna"])
        #expect(try e.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM call_segment_fts WHERE call_segment_fts MATCH 'hello'") } == 1)

        let audio = try #require(call.audioPath)
        #expect(audio == "calls/\(call.id)/upload.ogg")
        #expect(try Data(contentsOf: e.data.appendingPathComponent(audio)) == Data("OggS-fake-audio".utf8))

        let plain = try e.read { try ImportedCall.filter(sql: "source_id = ?", arguments: [WisprFixture.meetingNoFilesId]).fetchOne($0)! }
        #expect(plain.audioPath == nil && plain.summaryJson?.contains("delivered text") == true)
        #expect(try e.count("call_segment", "call_id = '\(plain.id)'") == 0)
    }

    @Test func meetingFallsBackToLiveTranscript() async throws {
        let e = try Env(); defer { e.cleanup() }
        try? FileManager.default.removeItem(at: e.wispr.appendingPathComponent("meetings/\(WisprFixture.meetingId)/refined.ndjson"))
        _ = try await e.importer.run(includeAudio: false)
        let segs = try e.read { try ImportedCallSegment.fetchAll($0) }
        #expect(segs.count == 1 && segs[0].text == "live hello" && segs[0].pass == "live" && segs[0].channel == "mic")
        #expect(segs[0].startMs == 1000 && segs[0].endMs == 2000)
    }

    @Test func configGivesSuggestions() async throws {
        let e = try Env(); defer { e.cleanup() }
        let report = try await e.importer.dryRun()
        #expect(report.suggestions.languages == ["en", "ru"])
        #expect(report.suggestions.shortcuts == ["59": "ptt", "59+63": "handsfree"])
    }

    @Test func reportIsStoredInImportRunAsJSON() async throws {
        let e = try Env(); defer { e.cleanup() }
        _ = try await e.importer.run(includeAudio: false)
        let json = try e.read { try ImportRun.fetchOne($0)!.reportJson }
        let report = try JSONDecoder().decode(ImportReport.self, from: Data(try #require(json).utf8))
        #expect(report.step("History")?.imported == 12 && !report.dryRun)
    }

    // MARK: Resume

    @Test func interruptedRunResumesFromCheckpointWithoutDuplicates() async throws {
        let e = try Env(bulk: 1300); defer { e.cleanup() }
        let importer = e.importer
        let task = Task {
            try await importer.run(includeAudio: false) { p in
                if p.step == "History", p.done >= 500 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let partial = try e.count("dictation")
        #expect(partial >= 500 && partial < 1312)
        #expect(FileManager.default.fileExists(atPath: e.data.appendingPathComponent("import/wispr-checkpoint.json").path))

        let report = try await e.importer.run(includeAudio: false)
        #expect(try e.count("dictation") == 1312)
        #expect(try e.read { try Int.fetchOne($0, sql: "SELECT COUNT(DISTINCT source_id) FROM dictation") } == 1312)
        #expect(report.notes.contains { $0.contains("продолжение") })
        #expect(report.step("History")?.imported == 1312 - partial)
        #expect(report.step("History")?.alreadyImported == partial)
    }
}

@Suite struct WisprMappingTests {
    @Test func textPriority() {
        #expect(WisprMapping.finalText(pasted: "p", formatted: "f", asr: "a") == "p")
        #expect(WisprMapping.finalText(pasted: nil, formatted: "f", asr: "a") == "f")
        #expect(WisprMapping.finalText(pasted: nil, formatted: nil, asr: "a") == "a")
        #expect(WisprMapping.finalText(pasted: nil, formatted: nil, asr: nil) == nil)
    }

    @Test func modesAndStatus() {
        #expect(WisprMapping.kindAndMode(command: "ptt") == (.dictation, .hold))
        #expect(WisprMapping.kindAndMode(command: "popo") == (.dictation, .handsfree))
        #expect(WisprMapping.kindAndMode(command: "command") == (.agent, nil))
        #expect(WisprMapping.status(wisprStatus: "error", archived: true) == .failed)
        #expect(WisprMapping.status(wisprStatus: "formatted", archived: true) == .archived)
        #expect(WisprMapping.status(wisprStatus: nil, archived: false) == .imported)
    }

    @Test func styleGroups() {
        #expect(WisprMapping.styleName(group: "work", bundleId: "com.googlecode.iterm2") == "Код")
        #expect(WisprMapping.styleName(group: "work", bundleId: "ru.keepcoder.Telegram") == "Мессенджеры")
        #expect(WisprMapping.styleName(group: "personal", bundleId: "x") == "Мессенджеры")
        #expect(WisprMapping.styleName(group: "unset", bundleId: "x") == nil)
        #expect(WisprMapping.dominantGroup(["work": 2, "other": 2, "email": 1]) == "other")
        #expect(WisprMapping.dominantGroup([:]) == nil)
    }

    @Test func wisprTimeFormats() {
        #expect(WisprTime.parse("2026-08-04 09:48:11.864 +00:00") == SusuTime.date("2026-08-04T09:48:11.864Z"))
        #expect(WisprTime.parse("2026-08-04 12:48:11.000 +03:00") == SusuTime.date("2026-08-04T09:48:11.000Z"))
        #expect(WisprTime.parse("2026-08-04T09:48:11Z") == SusuTime.date("2026-08-04T09:48:11.000Z"))
        #expect(WisprTime.parse("garbage") == nil)
        #expect(WisprTime.fromNumber(1_785_836_897_080) == Date(timeIntervalSince1970: 1_785_836_897.08))
    }
}
