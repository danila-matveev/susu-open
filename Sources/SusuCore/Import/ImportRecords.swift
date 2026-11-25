import Foundation
import GRDB

// Records for the tables only the importer writes (call, call_segment, call_speaker, import_run).
// The call records are internal and import-prefixed so the Calls module can define its own later.

public struct ImportRun: SusuRecord, Identifiable {
    public static let databaseTableName = "import_run"

    public var id: String
    public var at: Date
    public var source: String
    public var dryRun: Bool
    public var reportJson: String?
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: String = UUID().uuidString, at: Date = Date(), source: String = "wispr", dryRun: Bool,
                reportJson: String?, updatedAt: Date? = nil, deletedAt: Date? = nil) {
        self.id = id; self.at = at; self.source = source; self.dryRun = dryRun; self.reportJson = reportJson
        self.updatedAt = updatedAt ?? at; self.deletedAt = deletedAt
    }
}

struct ImportedCall: SusuRecord {
    static let databaseTableName = "call"
    var id: String
    var startedAt: Date
    var endedAt: Date?
    var title: String?
    var appBundleId: String?
    var calendarEventId: String?
    var participantsJson: String?
    var languageMode: String?
    var status: String
    var audioPath: String?
    var notes: String?
    var summaryJson: String?
    var sttProvider: String?
    var summaryModel: String?
    var costUsd: Double?
    var source: String
    var sourceId: String?
    var updatedAt: Date
    var deletedAt: Date?
}

struct ImportedCallSegment: SusuRecord {
    static let databaseTableName = "call_segment"
    var id: String
    var callId: String
    var channel: String
    var speakerKey: String?
    var startMs: Int
    var endMs: Int
    var text: String
    var pass: String
    var droppedEcho: Bool
    var updatedAt: Date
    var deletedAt: Date?
}

struct ImportedCallSpeaker: SusuRecord {
    static let databaseTableName = "call_speaker"
    var callId: String
    var speakerKey: String
    var displayName: String?
    var email: String?
    var confidence: Double?
    var updatedAt: Date
    var deletedAt: Date?
}
