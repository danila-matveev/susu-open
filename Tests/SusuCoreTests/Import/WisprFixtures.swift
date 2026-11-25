import Foundation
import GRDB
@testable import SusuCore

/// Synthetic Wispr Flow folders built by test code (the real database never goes into tests).
enum WisprFixture {
    enum Variant {
        /// Columns as in Wispr today (the subset the importer cares about plus a few it ignores).
        case current
        case noPastedTextNoAudio
        case noDictionary
        case extraColumns
    }

    static let styleNames = ["Код", "Мессенджеры", "Почта", "Задачи и заметки", "Прочее"]
    static let meetingId = "11111111-1111-1111-1111-111111111111"
    static let meetingNoFilesId = "22222222-2222-2222-2222-222222222222"

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("susu-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 16 kHz mono 16-bit WAV with a quiet tone, like Wispr's `History.audio` blobs.
    static func wav(seconds: Double = 0.6) -> Data {
        let rate = 16_000
        let n = Int(Double(rate) * seconds)
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + n * 2)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(n * 2)
        for i in 0..<n { u16(Int(Int16(8000 * sin(Double(i) * 2 * .pi * 440 / Double(rate))).magnitude) & 0xFFFF) }
        return d
    }

    /// Creates `<dir>/wispr/` with flow.sqlite, config.json and meetings/. Returns the Wispr folder.
    @discardableResult
    static func make(_ variant: Variant = .current, in dir: URL, extraHistoryRows: Int = 0) throws -> URL {
        let folder = dir.appendingPathComponent("wispr", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: folder.appendingPathComponent("flow.sqlite").path)
        let withPasted = variant != .noPastedTextNoAudio
        let withAudio = variant != .noPastedTextNoAudio
        let extra = variant == .extraColumns

        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE History (transcriptEntityId VARCHAR(36) NOT NULL UNIQUE PRIMARY KEY, asrText TEXT, formattedText TEXT,
                    editedText TEXT, timestamp DATETIME, \(withAudio ? "audio BLOB," : "") status VARCHAR(255), app VARCHAR(255),
                    url VARCHAR(255), e2eLatency FLOAT, duration FLOAT, language TEXT, isArchived TINYINT(1) NOT NULL DEFAULT 0,
                    \(withPasted ? "pastedText TEXT," : "") transcriptCommand TEXT, personalizationStyleSettings JSON
                    \(extra ? ", futureColumn TEXT, anotherNewThing INTEGER" : ""))
                """)
            func hist(_ id: String, asr: String?, formatted: String? = nil, pasted: String? = nil, edited: String? = nil,
                      ts: String? = "2026-08-04 09:48:11.864 +00:00", app: String? = nil, url: String? = nil, latency: Double? = nil,
                      duration: Double? = nil, archived: Bool = false, status: String? = "formatted", command: String? = "ptt",
                      group: String? = nil, audio: Data? = nil) throws {
                var cols = ["transcriptEntityId", "asrText", "formattedText", "editedText", "timestamp", "status", "app", "url",
                            "e2eLatency", "duration", "isArchived", "transcriptCommand", "personalizationStyleSettings"]
                let settings = group.map { "{\"personalizationAppType\":\"\($0)\",\"personalizationStyle\":\"casual\"}" }
                var args: [DatabaseValueConvertible?] = [id, asr, formatted, edited, ts, status, app, url, latency, duration,
                                                         archived ? 1 : 0, command, settings]
                if withPasted { cols.append("pastedText"); args.append(pasted) }
                if withAudio { cols.append("audio"); args.append(audio) }
                if extra { cols += ["futureColumn", "anotherNewThing"]; args += ["x", 7] }
                let marks = Array(repeating: "?", count: cols.count).joined(separator: ",")
                try db.execute(sql: "INSERT INTO History (\(cols.joined(separator: ","))) VALUES (\(marks))",
                               arguments: StatementArguments(args.map { $0?.databaseValue ?? DatabaseValue.null }))
            }
            let code = "com.microsoft.VSCode", tg = "ru.keepcoder.Telegram", mail = "com.apple.mail", web = "com.apple.Safari", slack = "com.tinyspeck.slackmacgap"
            try hist("h01", asr: "raw one", formatted: "formatted one", pasted: "pasted one", edited: "edited one",
                     app: code, url: nil, latency: 905, duration: 3.5, group: "work", audio: wav())
            try hist("h02", asr: "raw two", formatted: "formatted two", app: tg, latency: 1200, duration: 12, command: "popo", group: "personal")
            try hist("h03", asr: "raw three only", app: tg, status: "error", command: "command", group: "personal")
            try hist("h04", asr: "raw four", formatted: "formatted four", app: mail, archived: true, command: nil, group: "email")
            try hist("h05", asr: "raw five", ts: nil, app: nil, latency: 1_777_204_814_503, group: nil)
            try hist("h06", asr: "raw six", app: code, group: "work")
            try hist("h07", asr: "raw seven", app: code, group: "other")
            try hist("h08", asr: "raw eight", app: web, group: "other", audio: wav(seconds: 0.3))
            try hist("h09", asr: "raw nine", app: slack, group: "work")
            try hist("h10", asr: "raw ten", app: tg, group: "work")
            try hist("h11", asr: "raw eleven", app: tg, group: "personal")
            try hist("h12", asr: "raw twelve", app: "com.unknown.app", group: "unset")
            for i in 0..<extraHistoryRows {
                try hist(String(format: "x%05d", i), asr: "bulk \(i)", app: web, group: "other")
            }

            if variant != .noDictionary {
                try db.execute(sql: """
                    CREATE TABLE Dictionary (id VARCHAR(36) NOT NULL PRIMARY KEY, phrase VARCHAR(255) NOT NULL, replacement VARCHAR(255),
                        frequencyUsed INTEGER NOT NULL DEFAULT 0, createdAt DATETIME NOT NULL, isDeleted TINYINT(1) NOT NULL DEFAULT 0,
                        source VARCHAR(255), isSnippet TINYINT(1) NOT NULL DEFAULT 0, isStarred TINYINT(1) NOT NULL DEFAULT 0
                        \(extra ? ", futureColumn TEXT" : ""))
                    """)
                let ts = "2026-05-01 10:00:00.000 +00:00"
                try db.execute(sql: "INSERT INTO Dictionary (id, phrase, replacement, frequencyUsed, createdAt, source, isStarred) VALUES ('d1','Susu',NULL,4,?,'manual',1)", arguments: [ts])
                try db.execute(sql: "INSERT INTO Dictionary (id, phrase, replacement, createdAt, source) VALUES ('d2','люмирий','Lumera',?,'user_edits')", arguments: [ts])
                try db.execute(sql: "INSERT INTO Dictionary (id, phrase, replacement, createdAt, isSnippet, source) VALUES ('d3','мой адрес','ул. Тестовая, 1',?,1,'default')", arguments: [ts])
                try db.execute(sql: "INSERT INTO Dictionary (id, phrase, createdAt, isDeleted, source) VALUES ('d4','удалённое',?,1,'user_edits')", arguments: [ts])
            }

            try db.execute(sql: """
                CREATE TABLE Notes (id VARCHAR(36) NOT NULL PRIMARY KEY, title VARCHAR(255) NOT NULL, contentPreview TEXT NOT NULL,
                    content TEXT NOT NULL, createdAt DATETIME NOT NULL, modifiedAt DATETIME NOT NULL, isDeleted TINYINT(1) NOT NULL DEFAULT 0)
                """)
            try db.execute(sql: "INSERT INTO Notes VALUES ('n1','Plan','prev','Note body one','2026-06-01 08:00:00.000 +00:00','2026-06-01 08:00:00.000 +00:00',0)")
            try db.execute(sql: "INSERT INTO Notes VALUES ('n2','Second','prev','Body two','2026-06-02 08:00:00.000 +00:00','2026-06-02 08:00:00.000 +00:00',0)")
            try db.execute(sql: "INSERT INTO Notes VALUES ('n3','Gone','prev','Deleted','2026-06-03 08:00:00.000 +00:00','2026-06-03 08:00:00.000 +00:00',1)")

            try db.execute(sql: """
                CREATE TABLE Meetings (id VARCHAR(36) NOT NULL UNIQUE PRIMARY KEY, title VARCHAR(255) NOT NULL, createdAt DATETIME NOT NULL,
                    modifiedAt DATETIME NOT NULL, isDeleted TINYINT(1) NOT NULL DEFAULT 0, endedAt INTEGER DEFAULT NULL,
                    calendarEventExternalId VARCHAR(255) DEFAULT NULL, participantNames TEXT DEFAULT NULL, notes TEXT DEFAULT NULL,
                    summary TEXT DEFAULT NULL, deliveredSummary TEXT DEFAULT NULL, speakerMap TEXT DEFAULT NULL)
                """)
            let speakerMap = #"{"assignments":{"1":{"consensus":"p-self","mic":"p-self","dom":null,"llm":null,"user":null,"voices":[]},"2":{"consensus":"p-anna","mic":null,"dom":"p-anna","llm":null,"user":null,"voices":[]}},"people":{"p-self":{"name":"Me Myself","origin":"self","contactId":null},"p-anna":{"name":"Anna","origin":"calendar","contactId":null}}}"#
            try db.execute(sql: "INSERT INTO Meetings (id,title,createdAt,modifiedAt,endedAt,calendarEventExternalId,participantNames,notes,summary,speakerMap) VALUES (?,?,?,?,?,?,?,?,?,?)",
                           arguments: [meetingId, "Planning", "2026-08-04 09:00:00.000 +00:00", "2026-08-04 10:00:00.000 +00:00", 1_785_837_000_000,
                                       "cal-1", #"["Anna","Boris"]"#, "my notes", "# Summary\n- decided things", speakerMap])
            try db.execute(sql: "INSERT INTO Meetings (id,title,createdAt,modifiedAt,deliveredSummary) VALUES (?,?,?,?,?)",
                           arguments: [meetingNoFilesId, "No files", "2026-08-05 09:00:00.000 +00:00", "2026-08-05 09:00:00.000 +00:00", "delivered text"])
            try db.execute(sql: "INSERT INTO Meetings (id,title,createdAt,modifiedAt,isDeleted) VALUES ('33333333-3333-3333-3333-333333333333','Deleted','2026-08-06 09:00:00.000 +00:00','2026-08-06 09:00:00.000 +00:00',1)")
        }

        let dir = folder.appendingPathComponent("meetings/\(meetingId)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let refined = [
            #"{"id":"r1","speaker":{"id":1,"name":null,"source":"refined"},"text":"Hello everyone","timestamp":"2026-08-04T09:00:05.000Z"}"#,
            #"{"id":"r2","speaker":{"id":2,"name":null,"source":"refined"},"text":"Hi, ready to start","timestamp":"2026-08-04T09:00:09.500Z"}"#,
            "not json at all",
            #"{"id":"r3","speaker":{"id":2,"name":null,"source":"refined"},"text":"   ","timestamp":"2026-08-04T09:00:12.000Z"}"#,
        ].joined(separator: "\n")
        try refined.write(to: dir.appendingPathComponent("refined.ndjson"), atomically: true, encoding: .utf8)
        let live = [
            #"{"meta":{"clock":"epoch","v":1}}"#,
            #"{"epochMs":1,"id":"m1","marker":"pause","segment":0,"timestamp":"2026-08-04T09:00:01.000Z"}"#,
            #"{"endEpochMs":2000,"endRecordingMs":2000,"id":"l1","segment":0,"speaker":{"id":1,"name":null,"source":"mic"},"startEpochMs":1000,"startRecordingMs":1000,"text":"live hello","timestamp":"2026-08-04T09:00:02.000Z"}"#,
        ].joined(separator: "\n")
        try live.write(to: dir.appendingPathComponent("live.ndjson"), atomically: true, encoding: .utf8)
        try Data("OggS-fake-audio".utf8).write(to: dir.appendingPathComponent("upload.ogg"))

        let config = #"{"prefs":{"user":{"selectedLanguages":["en","ru"],"shortcuts":{"59":"ptt","59+63":"handsfree"},"personalizationStyles":{"work":"casual","email":"formal","other":"casual","unset":"default","personal":"veryCasual"}}}}"#
        try config.write(to: folder.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        return folder
    }

    /// Size and modification time of every file under `folder` (И1 compares this before and after).
    static func fingerprint(_ folder: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let fm = FileManager.default
        for case let url as URL in fm.enumerator(at: folder, includingPropertiesForKeys: nil)! {
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            result[url.path.replacingOccurrences(of: folder.path, with: "")] = "\(size)|\(mtime)"
        }
        return result
    }

    static func seedStyles(_ db: SusuDatabase, names: [String] = styleNames) throws {
        try db.writer.write { db in
            for (i, n) in names.enumerated() { try Style(name: n, sort: i).insert(db) }
        }
    }
}
