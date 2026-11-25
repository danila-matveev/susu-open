import Foundation
import GRDB

// Wispr Meetings + meetings/<id>/ -> call, call_segment, call_speaker (T4.4, format in docs/checks/T4.4.md).

extension WisprImportJob {
    func importMeetings(_ source: WisprSource) throws {
        let wanted = ["title", "createdAt", "endedAt", "isDeleted", "participantNames", "notes", "summary", "deliveredSummary",
                      "speakerMap", "calendarEventExternalId"]
        guard let table = try openTable("Meetings", id: "id", wanted: wanted, in: source, stepName: "Meetings") else { return }
        let existing = try existingSourceIds("call")
        let meetingsDir = importer.wisprFolder.appendingPathComponent("meetings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: meetingsDir.path) {
            report.notes.append("не найдено: папка meetings/ — созвоны без расшифровки")
        }
        var step = ImportReport.Step(name: "Meetings")
        step.total = try source.queue.read { try table.count(in: $0) }
        var last = checkpoint.lastId["Meetings"]
        var seen = 0
        while true {
            try Task.checkCancellation()
            let rows = try source.queue.read { try table.batch($0, after: last, limit: 20) }
            if rows.isEmpty { break }
            for row in rows {
                seen += 1
                guard let id = row.string("id") else { step.skip("нет id"); continue }
                if existing.contains(id) { continue }
                if row.bool("isDeleted") { step.skip("удалено в Wispr"); continue }
                try importMeeting(row, id: id, folder: meetingsDir.appendingPathComponent(id, isDirectory: true), step: &step)
            }
            last = rows.last?.string("id")
            checkpoint.lastId["Meetings"] = last
            if !dryRun { try saveCheckpoint() }
            emit("Meetings", seen, step.total)
        }
        report.steps.append(step)
    }

    private func importMeeting(_ row: WisprRow, id: String, folder: URL, step: inout ImportReport.Step) throws {
        let callId = UUID().uuidString
        let startedAt = row.date("createdAt") ?? importer.now
        let people = WisprSpeakers(json: row.string("speakerMap"))
        let transcript = WisprTranscript.read(folder: folder, callStart: startedAt, speakers: people)
        step.details["фраз", default: 0] += transcript.segments.count
        step.details["говорящих", default: 0] += transcript.speakers.count

        var audioPath: String?
        let ogg = folder.appendingPathComponent("upload.ogg")
        if FileManager.default.fileExists(atPath: ogg.path) {
            audioPath = "calls/\(callId)/upload.ogg"
            step.details["звук_ogg", default: 0] += 1
        }
        step.imported += 1
        if dryRun { return }

        if let audioPath {
            let dest = importer.dataDirectory.appendingPathComponent(audioPath)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: ogg, to: dest)  // copied as is, never played (spec 5.1)
        }
        let now = importer.now
        let call = ImportedCall(
            id: callId, startedAt: startedAt, endedAt: row.date("endedAt"), title: row.text("title"),
            calendarEventId: row.text("calendarEventExternalId"),
            participantsJson: Self.participantsJSON(row.string("participantNames")),
            status: "ready", audioPath: audioPath, notes: row.text("notes"),
            summaryJson: Self.summaryJSON(row.text("summary") ?? row.text("deliveredSummary")),
            source: "wispr", sourceId: id, updatedAt: startedAt)
        let segments = transcript.segments.map {
            ImportedCallSegment(id: UUID().uuidString, callId: callId, channel: $0.channel, speakerKey: $0.speakerKey,
                                startMs: $0.startMs, endMs: $0.endMs, text: $0.text, pass: $0.pass, droppedEcho: false,
                                updatedAt: now)
        }
        let speakers = transcript.speakers.map {
            ImportedCallSpeaker(callId: callId, speakerKey: $0.key, displayName: $0.name, email: nil, confidence: nil, updatedAt: now)
        }
        try db.writer.write { db in
            try call.insert(db)
            for s in segments { try s.insert(db) }
            for s in speakers { try s.insert(db) }
        }
    }

    static func participantsJSON(_ raw: String?) -> String? {
        guard let raw, let data = raw.data(using: .utf8),
              let names = (try? JSONSerialization.jsonObject(with: data)) as? [String], !names.isEmpty else { return nil }
        return jsonString(names.map { ["name": $0] })
    }

    /// Wispr keeps the summary as ready text, so it goes into `markdown`; the structured fields stay empty (spec 8.4 schema).
    static func summaryJSON(_ markdown: String?) -> String? {
        guard let markdown else { return nil }
        return jsonString(["summary": [String](), "decisions": [String](), "tasks": [String](), "open_questions": [String](),
                           "speakers": [String](), "markdown": markdown] as [String: Any])
    }

    private static func jsonString(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}

/// `Meetings.speakerMap`: who each numbered speaker is and which one is the microphone track.
struct WisprSpeakers {
    private var names: [Int: String] = [:]
    private var micIds: Set<Int> = []
    private(set) var selfName: String?

    init(json: String?) {
        guard let json, let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let people = root["people"] as? [String: Any] ?? [:]
        func name(of pid: String) -> String? {
            ((people[pid] as? [String: Any])?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        for (pid, p) in people {
            if let p = p as? [String: Any], p["origin"] as? String == "self" { selfName = name(of: pid) }
        }
        let assignments = root["assignments"] as? [String: Any] ?? [:]
        for (key, value) in assignments {
            guard let n = Int(key), let a = value as? [String: Any] else { continue }
            if a["mic"] is String { micIds.insert(n) }
            for field in ["consensus", "user", "mic", "dom", "llm"] {
                if let pid = a[field] as? String, let nm = name(of: pid) { names[n] = nm; break }
            }
        }
    }

    func name(for id: Int) -> String? { names[id] }
    func isMic(_ id: Int) -> Bool { micIds.contains(id) }
}

struct WisprTranscript {
    struct Segment {
        var channel: String, speakerKey: String, startMs: Int, endMs: Int, text: String, pass: String
    }
    var segments: [Segment] = []
    var speakers: [(key: String, name: String?)] = []

    /// Prefers `refined.ndjson` (final pass); falls back to `live.ndjson`. Unreadable lines are ignored.
    static func read(folder: URL, callStart: Date, speakers people: WisprSpeakers) -> WisprTranscript {
        let refined = lines(folder.appendingPathComponent("refined.ndjson")).filter { $0["text"] is String }
        let useRefined = !refined.isEmpty
        let raw = useRefined ? refined : lines(folder.appendingPathComponent("live.ndjson")).filter { $0["text"] is String }

        struct Item { var channel: String; var sid: Int; var name: String?; var text: String; var start: Int; var end: Int? }
        var items: [Item] = []
        let firstEpoch = raw.compactMap { ($0["startEpochMs"] as? NSNumber)?.int64Value }.min()
        for o in raw {
            guard let text = (o["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let sp = o["speaker"] as? [String: Any]
            let sid = (sp?["id"] as? NSNumber)?.intValue ?? 0
            let name = (sp?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if useRefined {
                let ts = (o["timestamp"] as? String).flatMap { WisprTime.parse($0) } ?? callStart
                let start = max(0, Int((ts.timeIntervalSince(callStart) * 1000).rounded()))
                items.append(Item(channel: people.isMic(sid) ? "mic" : "system", sid: sid, name: name, text: text, start: start, end: nil))
            } else {
                let channel = (sp?["source"] as? String) == "mic" ? "mic" : "system"
                let start = (o["startRecordingMs"] as? NSNumber)?.intValue
                    ?? ((o["startEpochMs"] as? NSNumber)?.int64Value).map { Int($0 - (firstEpoch ?? $0)) } ?? 0
                let end = (o["endRecordingMs"] as? NSNumber)?.intValue
                items.append(Item(channel: channel, sid: sid, name: name, text: text, start: max(0, start), end: end))
            }
        }
        var result = WisprTranscript()
        var seenKeys: [String: String?] = [:]
        var order: [String] = []
        for (i, it) in items.enumerated() {
            let key = "\(it.channel):\(it.sid)"
            let end = it.end ?? (i + 1 < items.count ? max(items[i + 1].start, it.start) : it.start)
            result.segments.append(Segment(channel: it.channel, speakerKey: key, startMs: it.start, endMs: max(end, it.start),
                                           text: it.text, pass: useRefined ? "final" : "live"))
            let resolved = people.name(for: it.sid) ?? it.name ?? (it.channel == "mic" ? people.selfName : nil)
            if seenKeys[key] == nil { order.append(key); seenKeys[key] = .some(resolved) }
            else if seenKeys[key]! == nil, let resolved { seenKeys[key] = .some(resolved) }
        }
        result.speakers = order.map { ($0, seenKeys[$0] ?? nil) }
        return result
    }

    private static func lines(_ url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }
}
