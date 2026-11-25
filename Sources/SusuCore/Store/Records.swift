import Foundation
import GRDB

// Records for spec 5.2 tables. Columns map by snake_case; times are ISO-8601 UTC text (SusuTime).
// Other tables (call, task_item, memory_fact, ...) exist in the schema; their records come with their tasks.

public protocol SusuRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {}

extension SusuRecord {
    public static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
    public static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .custom { SusuTime.string($0) }
    }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .custom { dbValue in String.fromDatabaseValue(dbValue).flatMap(SusuTime.date) }
    }
}

// MARK: - Dictation

public enum DictationKind: String, Codable, Sendable, DatabaseValueConvertible { case dictation, agent }
public enum DictationMode: String, Codable, Sendable, DatabaseValueConvertible { case hold, handsfree }
public enum DictationStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case inserted, copiedOnly = "copied_only", notInserted = "not_inserted", cancelled, failed, imported, archived
}

public struct Dictation: SusuRecord, Identifiable {
    public static let databaseTableName = "dictation"

    public var id: String
    public var kind: DictationKind
    public var createdAt: Date
    public var durationMs: Int?
    public var mode: DictationMode?
    public var status: DictationStatus
    public var appName: String?
    public var bundleId: String?
    public var windowTitle: String?
    public var url: String?
    public var styleId: String?
    public var sttProvider: String?
    public var sttModel: String?
    public var editorModel: String?
    public var fallbackUsed: Bool
    public var rawText: String?
    public var finalText: String?
    public var editedText: String?
    public var language: String?
    /// Key released -> target app took the text, ms.
    public var latencyMs: Int?
    /// File on disk, nil once the audio is deleted. Relative paths resolve against `HistoryStore.baseDirectory`.
    public var audioPath: String?
    public var costUsd: Double?
    public var source: String
    public var sourceId: String?
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString, kind: DictationKind = .dictation, createdAt: Date = Date(),
        durationMs: Int? = nil, mode: DictationMode? = nil, status: DictationStatus = .inserted,
        appName: String? = nil, bundleId: String? = nil, windowTitle: String? = nil, url: String? = nil,
        styleId: String? = nil, sttProvider: String? = nil, sttModel: String? = nil, editorModel: String? = nil,
        fallbackUsed: Bool = false, rawText: String? = nil, finalText: String? = nil, editedText: String? = nil,
        language: String? = nil, latencyMs: Int? = nil, audioPath: String? = nil, costUsd: Double? = nil,
        source: String = "susu", sourceId: String? = nil, updatedAt: Date? = nil, deletedAt: Date? = nil
    ) {
        self.id = id; self.kind = kind; self.createdAt = createdAt; self.durationMs = durationMs
        self.mode = mode; self.status = status; self.appName = appName; self.bundleId = bundleId
        self.windowTitle = windowTitle; self.url = url; self.styleId = styleId
        self.sttProvider = sttProvider; self.sttModel = sttModel; self.editorModel = editorModel
        self.fallbackUsed = fallbackUsed; self.rawText = rawText; self.finalText = finalText
        self.editedText = editedText; self.language = language; self.latencyMs = latencyMs
        self.audioPath = audioPath; self.costUsd = costUsd; self.source = source; self.sourceId = sourceId
        self.updatedAt = updatedAt ?? createdAt; self.deletedAt = deletedAt
    }
}

// MARK: - Spend

public struct Spend: SusuRecord, Identifiable {
    public static let databaseTableName = "spend"

    public var id: String
    public var at: Date
    /// `dictation` / `editor` / `judge` / `call_stt` / `summary` / `agent`
    public var task: String
    public var provider: String?
    public var model: String?
    public var audioSeconds: Double?
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var costUsd: Double
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: String = UUID().uuidString, at: Date = Date(), task: String, provider: String? = nil,
                model: String? = nil, audioSeconds: Double? = nil, tokensIn: Int? = nil, tokensOut: Int? = nil,
                costUsd: Double = 0, updatedAt: Date? = nil, deletedAt: Date? = nil) {
        self.id = id; self.at = at; self.task = task; self.provider = provider; self.model = model
        self.audioSeconds = audioSeconds; self.tokensIn = tokensIn; self.tokensOut = tokensOut
        self.costUsd = costUsd; self.updatedAt = updatedAt ?? at; self.deletedAt = deletedAt
    }
}

// MARK: - Dictionary

public struct DictionaryEntry: SusuRecord, Identifiable {
    public static let databaseTableName = "dictionary_entry"

    public var id: String
    /// `word` / `replacement` / `snippet`
    public var kind: String
    public var phrase: String
    public var replacement: String?
    public var starred: Bool
    /// `manual` / `learned` / `wispr` / `history`
    public var origin: String
    public var useCount: Int
    public var createdAt: Date
    public var source: String?
    public var sourceId: String?
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: String = UUID().uuidString, kind: String = "word", phrase: String, replacement: String? = nil,
                starred: Bool = false, origin: String = "manual", useCount: Int = 0, createdAt: Date = Date(),
                source: String? = nil, sourceId: String? = nil, updatedAt: Date? = nil, deletedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.phrase = phrase; self.replacement = replacement
        self.starred = starred; self.origin = origin; self.useCount = useCount; self.createdAt = createdAt
        self.source = source; self.sourceId = sourceId; self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }
}

// MARK: - Style

public struct Style: SusuRecord, Identifiable {
    public static let databaseTableName = "style"

    public var id: String
    public var name: String
    public var prompt: String
    /// `verbatim` / `names` / `normal` / `careful`
    public var cleanupLevel: String
    public var voiceCommands: Bool
    public var isDefault: Bool
    public var sort: Int
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: String = UUID().uuidString, name: String, prompt: String = "", cleanupLevel: String = "normal",
                voiceCommands: Bool = false, isDefault: Bool = false, sort: Int = 0,
                updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.name = name; self.prompt = prompt; self.cleanupLevel = cleanupLevel
        self.voiceCommands = voiceCommands; self.isDefault = isDefault; self.sort = sort
        self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

public struct StyleRule: SusuRecord, Identifiable {
    public static let databaseTableName = "style_rule"

    public var id: String
    public var styleId: String
    /// `bundle` / `url` / `title`
    public var kind: String
    public var pattern: String
    public var priority: Int
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: String = UUID().uuidString, styleId: String, kind: String, pattern: String, priority: Int = 0,
                updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.styleId = styleId; self.kind = kind; self.pattern = pattern
        self.priority = priority; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

// MARK: - Note

public struct Note: SusuRecord, Identifiable {
    public static let databaseTableName = "note"

    public var id: String
    public var createdAt: Date
    public var title: String?
    public var text: String?
    public var tagsJson: String?
    public var audioPath: String?
    /// `hotkey` / `agent` / `wispr` / `manual`
    public var origin: String
    public var source: String?
    public var sourceId: String?
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: String = UUID().uuidString, createdAt: Date = Date(), title: String? = nil, text: String? = nil,
                tagsJson: String? = nil, audioPath: String? = nil, origin: String = "manual",
                source: String? = nil, sourceId: String? = nil, updatedAt: Date? = nil, deletedAt: Date? = nil) {
        self.id = id; self.createdAt = createdAt; self.title = title; self.text = text
        self.tagsJson = tagsJson; self.audioPath = audioPath; self.origin = origin
        self.source = source; self.sourceId = sourceId; self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }
}
