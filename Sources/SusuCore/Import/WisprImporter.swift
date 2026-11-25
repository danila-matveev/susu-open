import Foundation
import GRDB

/// Moves a user's data out of Wispr Flow into Susu (spec 6).
///
/// Safety (И1): the Wispr database is opened read-only only to take a snapshot (SQLite Online Backup);
/// everything else works on the snapshot. Nothing is ever written into the Wispr folder.
/// Re-running is safe (И6): rows are keyed by `source = wispr` + the Wispr id. An interrupted run
/// continues from `import/wispr-checkpoint.json` (last imported id per table).
public final class WisprImporter: Sendable {
    public let database: SusuDatabase
    /// Susu data directory (`~/Library/Application Support/Susu`).
    public let dataDirectory: URL
    /// The Wispr Flow folder (holds `flow.sqlite`, `config.json`, `meetings/`).
    public let wisprFolder: URL
    private let clock: @Sendable () -> Date

    public init(database: SusuDatabase, dataDirectory: URL, wisprFolder: URL,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.dataDirectory = dataDirectory
        self.wisprFolder = wisprFolder
        self.clock = clock
    }

    /// Default Wispr folder: `~/Library/Application Support/Wispr Flow`.
    public static func defaultWisprFolder() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("Wispr Flow", isDirectory: true)
    }

    /// Counts per step without writing anything except the report in `import_run`.
    public func dryRun(progress: ImportProgressHandler? = nil) async throws -> ImportReport {
        try await execute(dryRun: true, includeAudio: true, progress: progress)
    }

    /// Real import. Audio conversion (WAV -> m4a) runs last, after all rows; pass `includeAudio: false` to skip it.
    public func run(includeAudio: Bool = true, progress: ImportProgressHandler? = nil) async throws -> ImportReport {
        try await execute(dryRun: false, includeAudio: includeAudio, progress: progress)
    }

    private func execute(dryRun: Bool, includeAudio: Bool, progress: ImportProgressHandler?) async throws -> ImportReport {
        let job = try WisprImportJob(importer: self, dryRun: dryRun, includeAudio: includeAudio, progress: progress)
        return try await job.execute()
    }

    var importDirectory: URL { dataDirectory.appendingPathComponent("import", isDirectory: true) }
    var checkpointURL: URL { importDirectory.appendingPathComponent("wispr-checkpoint.json") }
    var now: Date { clock() }
}

// MARK: - One run

struct WisprCheckpoint: Codable {
    var snapshot: String
    var lastId: [String: String] = [:]
    var done: [String] = []
}

final class WisprImportJob {
    let importer: WisprImporter
    let dryRun: Bool
    let includeAudio: Bool
    let progress: ImportProgressHandler?
    var report: ImportReport
    var checkpoint: WisprCheckpoint
    let snapshotURL: URL
    let batchSize = 500

    var db: SusuDatabase { importer.database }
    var fm: FileManager { FileManager.default }

    init(importer: WisprImporter, dryRun: Bool, includeAudio: Bool, progress: ImportProgressHandler?) throws {
        self.importer = importer
        self.dryRun = dryRun
        self.includeAudio = includeAudio
        self.progress = progress
        report = ImportReport(dryRun: dryRun)
        let day = String(SusuTime.string(importer.now).prefix(10))
        if !dryRun, let data = try? Data(contentsOf: importer.checkpointURL),
           let saved = try? JSONDecoder().decode(WisprCheckpoint.self, from: data),
           FileManager.default.fileExists(atPath: importer.importDirectory.appendingPathComponent(saved.snapshot).path) {
            checkpoint = saved
        } else {
            checkpoint = WisprCheckpoint(snapshot: "wispr-snapshot-\(day)\(dryRun ? "-dry" : "").sqlite")
        }
        snapshotURL = importer.importDirectory.appendingPathComponent(checkpoint.snapshot)
    }

    func execute() async throws -> ImportReport {
        let resuming = fm.fileExists(atPath: snapshotURL.path) && !dryRun
        if !resuming {
            let ignoredWAL = try WisprSnapshot.make(from: importer.wisprFolder.appendingPathComponent("flow.sqlite"), to: snapshotURL)
            if ignoredWAL {
                report.notes.append("в папке Wispr остался журнал без служебного файла: снимок взят без последних записей — закройте Wispr и повторите")
            }
            if !dryRun { try saveCheckpoint() }
        } else {
            report.notes.append("продолжение прерванного переноса: часть строк уже перенесена в прошлый раз")
        }

        let source = try WisprSource(snapshot: snapshotURL)
        loadConfig()
        try await stepIfNeeded("History") { try self.importHistory(source) }
        try await stepIfNeeded("Dictionary") { try self.importDictionary(source) }
        try await stepIfNeeded("Styles") { try self.importStyles(source) }
        try await stepIfNeeded("Notes") { try self.importNotes(source) }
        try await stepIfNeeded("Meetings") { try self.importMeetings(source) }
        if includeAudio { try await stepIfNeeded("Audio") { try self.importAudio(source) } }

        for i in report.steps.indices {
            var s = report.steps[i]
            s.alreadyImported = max(0, s.total - s.imported - s.skipped)
            report.steps[i] = s
        }
        try saveReport()
        WisprSnapshot.removeFiles(of: snapshotURL)
        try? fm.removeItem(at: importer.checkpointURL)
        return report
    }

    private func stepIfNeeded(_ name: String, _ body: () throws -> Void) async throws {
        try Task.checkCancellation()
        if checkpoint.done.contains(name) {
            report.notes.append("шаг \(name) был закончен в прошлом запуске")
            return
        }
        try body()
        checkpoint.done.append(name)
        checkpoint.lastId[name] = nil
        if !dryRun { try saveCheckpoint() }
        await Task.yield()
    }

    func saveCheckpoint() throws {
        try fm.createDirectory(at: importer.importDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(checkpoint).write(to: importer.checkpointURL, options: .atomic)
    }

    func saveReport() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = String(decoding: try enc.encode(report), as: UTF8.self)
        let run = ImportRun(at: importer.now, dryRun: dryRun, reportJson: json)
        try db.writer.write { try run.insert($0) }
    }

    func emit(_ step: String, _ done: Int, _ total: Int) { progress?(ImportProgress(step: step, done: done, total: total)) }

    func existingSourceIds(_ table: String) throws -> Set<String> {
        try db.writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT source_id FROM \(table) WHERE source = 'wispr' AND source_id IS NOT NULL"))
        }
    }

    /// Opens a table for a step; records missing columns, or a note and nil when the table is unusable.
    func openTable(_ name: String, id: String, wanted: [String], in source: WisprSource, stepName: String) throws -> WisprTable? {
        guard let table = try WisprTable.inspect(name, idColumn: id, wanted: wanted, in: source) else {
            var step = ImportReport.Step(name: stepName)
            step.note = "таблица \(name) не найдена — шаг пропущен"
            report.steps.append(step)
            report.notes.append(step.note!)
            return nil
        }
        report.noteMissing(table: name, columns: table.missing)
        return table
    }

    /// Generic keyset-paged pass over a Wispr table. `make` returns the Susu record or a skip reason.
    func pump<R: SusuRecord>(
        _ table: WisprTable, step stepName: String, source: WisprSource, existing: Set<String>,
        make: (WisprRow, String) -> Result<R, SkipReason>
    ) throws {
        var step = ImportReport.Step(name: stepName)
        step.total = try source.queue.read { try table.count(in: $0) }
        var last = checkpoint.lastId[stepName]
        var seen = 0
        while true {
            try Task.checkCancellation()
            let rows = try source.queue.read { try table.batch($0, after: last, limit: batchSize) }
            if rows.isEmpty { break }
            var records: [R] = []
            for row in rows {
                guard let id = row.string(table.idColumn) else { step.skip("нет id"); continue }
                if existing.contains(id) { continue }
                switch make(row, id) {
                case .success(let r): records.append(r)
                case .failure(let reason): step.skip(reason.text)
                }
            }
            step.imported += records.count
            if !dryRun {
                try db.writer.write { db in for r in records { try r.insert(db, onConflict: .ignore) } }
            }
            last = row_id(rows.last!, table)
            checkpoint.lastId[stepName] = last
            if !dryRun { try saveCheckpoint() }
            seen += rows.count
            emit(stepName, seen, step.total)
        }
        report.steps.append(step)
    }

    private func row_id(_ row: WisprRow, _ table: WisprTable) -> String? { row.string(table.idColumn) }

    struct SkipReason: Error { let text: String }

    // MARK: History -> dictation

    func importHistory(_ source: WisprSource) throws {
        let wanted = ["asrText", "formattedText", "editedText", "pastedText", "timestamp", "app", "url", "e2eLatency",
                      "duration", "language", "isArchived", "status", "transcriptCommand", "audio"]
        guard let table = try openTable("History", id: "transcriptEntityId", wanted: wanted, in: source, stepName: "History") else { return }
        let existing = try existingSourceIds("dictation")
        let now = importer.now
        var noTime = 0
        try pump(table, step: "History", source: source, existing: existing) { (row, id) -> Result<Dictation, SkipReason> in
            let asr = row.text("asrText")
            let (kind, mode) = WisprMapping.kindAndMode(command: row.text("transcriptCommand"))
            let createdAt: Date
            if let t = row.date("timestamp") { createdAt = t } else { createdAt = now; noTime += 1 }
            return .success(Dictation(
                kind: kind, createdAt: createdAt, durationMs: WisprMapping.durationMs(seconds: row.double("duration")),
                mode: mode, status: WisprMapping.status(wisprStatus: row.string("status"), archived: row.bool("isArchived")),
                bundleId: row.text("app"), url: row.text("url"),
                rawText: asr,
                finalText: WisprMapping.finalText(pasted: row.text("pastedText"), formatted: row.text("formattedText"), asr: asr),
                editedText: row.text("editedText"), language: row.text("language"),
                latencyMs: WisprMapping.latencyMs(row.double("e2eLatency")),
                source: "wispr", sourceId: id))
        }
        if noTime > 0 { report.notes.append("History: у \(noTime) записей нет времени — поставлено время переноса") }
    }

    // MARK: Dictionary -> dictionary_entry

    func importDictionary(_ source: WisprSource) throws {
        let wanted = ["phrase", "replacement", "isDeleted", "isSnippet", "isStarred", "frequencyUsed", "createdAt"]
        guard let table = try openTable("Dictionary", id: "id", wanted: wanted, in: source, stepName: "Dictionary") else { return }
        let existing = try existingSourceIds("dictionary_entry")
        let now = importer.now
        try pump(table, step: "Dictionary", source: source, existing: existing) { (row, id) -> Result<DictionaryEntry, SkipReason> in
            if row.bool("isDeleted") { return .failure(SkipReason(text: "удалено в Wispr")) }
            guard let phrase = row.text("phrase") else { return .failure(SkipReason(text: "пустая фраза")) }
            let replacement = row.text("replacement")
            return .success(DictionaryEntry(
                kind: WisprMapping.dictionaryKind(isSnippet: row.bool("isSnippet"), replacement: replacement),
                phrase: phrase, replacement: replacement, starred: row.bool("isStarred"), origin: "wispr",
                useCount: max(0, row.int("frequencyUsed") ?? 0), createdAt: row.date("createdAt") ?? now,
                source: "wispr", sourceId: id))
        }
    }

    // MARK: Notes -> note

    func importNotes(_ source: WisprSource) throws {
        let wanted = ["title", "content", "createdAt", "isDeleted"]
        guard let table = try openTable("Notes", id: "id", wanted: wanted, in: source, stepName: "Notes") else { return }
        let existing = try existingSourceIds("note")
        let now = importer.now
        try pump(table, step: "Notes", source: source, existing: existing) { (row, id) -> Result<Note, SkipReason> in
            if row.bool("isDeleted") { return .failure(SkipReason(text: "удалено в Wispr")) }
            return .success(Note(createdAt: row.date("createdAt") ?? now, title: row.text("title"), text: row.string("content"),
                                 origin: "wispr", source: "wispr", sourceId: id))
        }
    }

    // MARK: History.app + personalizationStyleSettings -> style_rule (И5)

    func importStyles(_ source: WisprSource) throws {
        var step = ImportReport.Step(name: "Styles")
        guard let cols = try source.columns(of: "History"), cols.contains("app"),
              cols.contains("personalizationStyleSettings") else {
            step.note = "нет данных о группах программ (History.app / personalizationStyleSettings) — правила стилей не созданы"
            report.steps.append(step)
            report.notes.append(step.note!)
            return
        }
        let rows = try source.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT "app" AS app,
                       CASE WHEN json_valid("personalizationStyleSettings")
                            THEN json_extract("personalizationStyleSettings", '$.personalizationAppType') END AS grp,
                       COUNT(*) AS n
                FROM "History" WHERE "app" IS NOT NULL AND "app" <> '' GROUP BY 1, 2
                """)
        }
        var perApp: [String: [String: Int]] = [:]
        for r in rows {
            let app: String = r["app"]
            let n: Int = r["n"]
            if let g = String.fromDatabaseValue(r["grp"] as DatabaseValue), g != "unset" {
                perApp[app, default: [:]][g, default: 0] += n
            } else {
                perApp[app, default: [:]] = perApp[app, default: [:]]
            }
        }
        step.total = perApp.count
        let styles: [String: String] = try db.writer.read { db in
            var map: [String: String] = [:]
            for s in try Style.filter(sql: "deleted_at IS NULL").order(sql: "sort, name").fetchAll(db) where map[s.name] == nil {
                map[s.name] = s.id
            }
            return map
        }
        let existingPatterns: Set<String> = try db.writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT pattern FROM style_rule WHERE kind = 'bundle' AND deleted_at IS NULL"))
        }
        var toInsert: [StyleRule] = []
        for app in perApp.keys.sorted() {
            guard let group = WisprMapping.dominantGroup(perApp[app] ?? [:]) else { step.skip("у программы нет группы Wispr"); continue }
            guard let styleName = WisprMapping.styleName(group: group, bundleId: app) else { step.skip("группа «\(group)» не сопоставлена"); continue }
            if existingPatterns.contains(app) { step.alreadyImported += 1; continue }
            guard let styleId = styles[styleName] else { step.skip("стиль «\(styleName)» не найден в Susu"); continue }
            toInsert.append(StyleRule(styleId: styleId, kind: "bundle", pattern: app, priority: 0))
        }
        step.imported = toInsert.count
        if !dryRun { try db.writer.write { db in for r in toInsert { try r.insert(db) } } }
        step.details["правил_уже_было"] = step.alreadyImported
        step.alreadyImported = 0  // recomputed from total at the end; keep the visible count in details
        report.steps.append(step)
        emit("Styles", step.total, step.total)
    }

    // MARK: config.json -> suggestions

    func loadConfig() {
        let url = importer.wisprFolder.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url) else {
            report.notes.append("не найдено: config.json (клавиши и языки не предложены)")
            return
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let user = (root["prefs"] as? [String: Any])?["user"] as? [String: Any] else {
            report.notes.append("не найдено: prefs.user в config.json")
            return
        }
        if let s = user["shortcuts"] as? [String: Any] {
            for (k, v) in s { if let a = v as? String { report.suggestions.shortcuts[k] = a } }
        } else { report.notes.append("не найдено: config.json prefs.user.shortcuts") }
        if let l = user["selectedLanguages"] as? [String] { report.suggestions.languages = l }
        else { report.notes.append("не найдено: config.json prefs.user.selectedLanguages") }
        if let g = user["personalizationStyles"] as? [String: Any] {
            for (k, v) in g { if let n = v as? String { report.suggestions.styleGroups[k] = n } }
        } else { report.notes.append("не найдено: config.json prefs.user.personalizationStyles") }
    }

    // MARK: History.audio -> m4a (И3)

    func importAudio(_ source: WisprSource) throws {
        var step = ImportReport.Step(name: "Audio")
        guard let cols = try source.columns(of: "History"), cols.contains("audio"), cols.contains("transcriptEntityId") else {
            step.note = "в History нет колонки audio — звук не переносится"
            report.steps.append(step)
            return
        }
        let after = checkpoint.lastId["Audio"]
        let ids: [String] = try source.queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT "transcriptEntityId" FROM "History" WHERE "audio" IS NOT NULL AND length("audio") > 0
                ORDER BY "transcriptEntityId"
                """)
        }
        step.total = ids.count
        var done = 0
        for id in ids {
            try Task.checkCancellation()
            done += 1
            if let after, id <= after { continue }
            let target: (id: String, createdAt: String, audioPath: String?)? = try db.writer.read { db in
                try Row.fetchOne(db, sql: "SELECT id, created_at, audio_path FROM dictation WHERE source = 'wispr' AND source_id = ?",
                                 arguments: [id]).map { ($0["id"], $0["created_at"], $0["audio_path"]) }
            }
            guard let target else {
                if dryRun { step.imported += 1 } else { step.skip("диктовка не найдена в Susu") }
                continue
            }
            if target.audioPath != nil { continue }  // already converted -> counted as alreadyImported at the end
            if dryRun { step.imported += 1; continue }
            let wav: Data? = try source.queue.read { db in
                try Row.fetchOne(db, sql: #"SELECT "audio" FROM "History" WHERE "transcriptEntityId" = ?"#, arguments: [id])
                    .flatMap { WisprRow(row: $0).data("audio") }
            }
            guard let wav else { step.skip("звук пустой"); continue }
            let created = target.createdAt
            let rel = "audio/dictations/\(created.prefix(4))/\(created.dropFirst(5).prefix(2))/\(target.id).m4a"
            do {
                try WisprAudio.convertWAVToM4A(wav: wav, workDirectory: importer.importDirectory,
                                               to: importer.dataDirectory.appendingPathComponent(rel))
                try db.writer.write {
                    try $0.execute(sql: "UPDATE dictation SET audio_path = ? WHERE id = ?", arguments: [rel, target.id])
                }
                step.imported += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                step.skip("не удалось сконвертировать звук")
            }
            checkpoint.lastId["Audio"] = id
            if done % 25 == 0 { try saveCheckpoint(); emit("Audio", done, step.total) }
        }
        emit("Audio", step.total, step.total)
        report.steps.append(step)
    }
}
