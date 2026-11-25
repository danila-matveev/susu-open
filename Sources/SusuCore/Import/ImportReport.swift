import Foundation

/// One line of progress for the UI: which step, how far.
public struct ImportProgress: Sendable, Equatable {
    public var step: String
    public var done: Int
    public var total: Int
}

public typealias ImportProgressHandler = @Sendable (ImportProgress) -> Void

/// What an import (or dry run) did, per spec 6: moved / skipped with reason / columns not found.
public struct ImportReport: Codable, Sendable, Equatable {
    public struct Step: Codable, Sendable, Equatable {
        public var name: String
        /// Rows found in Wispr.
        public var total = 0
        /// Rows written now (dry run: rows that would be written).
        public var imported = 0
        /// Rows already in Susu from an earlier run (no duplicates, И6).
        public var alreadyImported = 0
        public var skipped = 0
        public var skipReasons: [String: Int] = [:]
        /// Extra counters (calls: segments, speakers, audio files copied).
        public var details: [String: Int] = [:]
        /// Why the whole step was skipped (missing table, ...).
        public var note: String?

        public init(name: String) { self.name = name }

        mutating func skip(_ reason: String) {
            skipped += 1
            skipReasons[reason, default: 0] += 1
        }
    }

    public struct Suggestions: Codable, Sendable, Equatable {
        /// Wispr key combination (key codes joined by `+`) -> its action name.
        public var shortcuts: [String: String] = [:]
        public var languages: [String] = []
        /// Wispr app group (work/email/personal/other) -> Wispr style name, for the style hint.
        public var styleGroups: [String: String] = [:]
    }

    public var dryRun: Bool
    public var steps: [Step] = []
    /// table -> columns that were not found.
    public var missingColumns: [String: [String]] = [:]
    /// Human-readable notes in Russian («не найдено: …», «шаг пропущен»).
    public var notes: [String] = []
    public var suggestions = Suggestions()

    public init(dryRun: Bool) { self.dryRun = dryRun }

    public func step(_ name: String) -> Step? { steps.first { $0.name == name } }

    mutating func noteMissing(table: String, columns: [String]) {
        guard !columns.isEmpty else { return }
        missingColumns[table] = columns
        for c in columns { notes.append("не найдено: \(table).\(c)") }
    }
}
