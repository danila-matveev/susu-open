import Foundation
import GRDB

/// Dictionary, replacements and snippets (spec 1.6, 3.7, 5.2 `dictionary_entry`).
/// Deleting is soft; the UI offers "Undo" for 5 s and calls `restore(id:)`.
public final class DictionaryService: Sendable {
    public enum Kind {
        public static let word = "word"
        public static let replacement = "replacement"
        public static let snippet = "snippet"
    }

    let database: SusuDatabase
    private var writer: any DatabaseWriter { database.writer }

    public init(database: SusuDatabase) { self.database = database }

    // MARK: Write

    /// Adds an entry. An active entry of the same kind with the same phrase (case-insensitive) is returned unchanged
    /// instead of creating a duplicate.
    @discardableResult
    public func add(kind: String = Kind.word, phrase: String, replacement: String? = nil, starred: Bool = false,
                    origin: String = "manual", source: String? = nil, sourceId: String? = nil,
                    now: Date = Date()) async throws -> DictionaryEntry {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return try await writer.write { db in
            // SQLite lower() only handles ASCII, so Cyrillic is compared in Swift.
            let key = EditLearner.normalize(phrase)
            if let existing = try DictionaryEntry
                .filter(sql: "kind = ? AND deleted_at IS NULL", arguments: [kind])
                .fetchAll(db).first(where: { EditLearner.normalize($0.phrase) == key }) {
                return existing
            }
            let entry = DictionaryEntry(kind: kind, phrase: phrase, replacement: replacement, starred: starred,
                                        origin: origin, createdAt: now, source: source, sourceId: sourceId)
            try entry.insert(db)
            return entry
        }
    }

    /// Reads, mutates and writes back in one transaction; `updated_at` is bumped by the trigger.
    @discardableResult
    public func update(id: String, _ mutate: @Sendable (inout DictionaryEntry) -> Void) async throws -> DictionaryEntry? {
        try await writer.write { db in
            guard var e = try DictionaryEntry.fetchOne(db, key: id), e.deletedAt == nil else { return nil }
            mutate(&e)
            e.id = id
            try e.update(db)
            return try DictionaryEntry.fetchOne(db, key: id)
        }
    }

    public func setStarred(id: String, _ starred: Bool) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE dictionary_entry SET starred = ? WHERE id = ? AND deleted_at IS NULL",
                           arguments: [starred, id])
        }
    }

    public func softDelete(id: String, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE dictionary_entry SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL",
                           arguments: [SusuTime.string(now), id])
        }
    }

    /// Undoes `softDelete`. Returns the entry, or nil if the id is unknown.
    @discardableResult
    public func restore(id: String) async throws -> DictionaryEntry? {
        try await writer.write { db in
            try db.execute(sql: "UPDATE dictionary_entry SET deleted_at = NULL WHERE id = ?", arguments: [id])
            return try DictionaryEntry.fetchOne(db, key: id)
        }
    }

    /// Counts one use for each applied entry (replacement applied, snippet expanded, ...).
    public func recordUse(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await writer.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE dictionary_entry SET use_count = use_count + 1 WHERE id = ? AND deleted_at IS NULL",
                               arguments: [id])
            }
        }
    }

    // MARK: Read

    public func entry(id: String) async throws -> DictionaryEntry? {
        try await writer.read { db in
            try DictionaryEntry.fetchOne(db, sql: "SELECT * FROM dictionary_entry WHERE id = ? AND deleted_at IS NULL",
                                         arguments: [id])
        }
    }

    /// Live entries, starred first, then most used, then newest. `query` matches phrase or replacement
    /// (case-insensitive substring); `origin` is `manual` / `learned` / `wispr` / `history`.
    public func list(kind: String? = nil, origin: String? = nil, query: String? = nil) async throws -> [DictionaryEntry] {
        try await writer.read { db in
            var clauses = ["deleted_at IS NULL"]
            var args: [any DatabaseValueConvertible] = []
            if let kind { clauses.append("kind = ?"); args.append(kind) }
            if let origin { clauses.append("origin = ?"); args.append(origin) }
            let rows = try DictionaryEntry.fetchAll(
                db,
                sql: "SELECT * FROM dictionary_entry WHERE \(clauses.joined(separator: " AND ")) " + Self.order,
                arguments: StatementArguments(args))
            // Case-insensitive search in Swift (SQLite lower() is ASCII-only).
            guard let q = query.map(EditLearner.normalize), !q.isEmpty else { return rows }
            return rows.filter {
                EditLearner.normalize($0.phrase).contains(q) || EditLearner.normalize($0.replacement ?? "").contains(q)
            }
        }
    }

    private static let order = "ORDER BY starred DESC, use_count DESC, created_at DESC, rowid DESC"

    /// Correct spellings to feed the recognizer, best first: starred, then most used, then newest.
    /// Words contribute their phrase, replacements their target; snippets are not hints. Case-insensitive duplicates
    /// are dropped. The caller (STTHintBuilder) fits the list to provider limits.
    public func hintTerms(limit: Int = 200) async throws -> [String] {
        let rows = try await writer.read { db in
            try DictionaryEntry.fetchAll(
                db, sql: "SELECT * FROM dictionary_entry WHERE deleted_at IS NULL AND kind != 'snippet' " + Self.order)
        }
        var seen = Set<String>()
        var out: [String] = []
        for e in rows {
            let term = e.kind == Kind.replacement ? (e.replacement ?? "") : e.phrase
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            out.append(term)
            if out.count >= limit { break }
        }
        return out
    }

    /// Replacement rules: wrong phrase -> right text. Entries are returned with ids via `replacementEntries()`.
    public func replacements() async throws -> [(phrase: String, replacement: String)] {
        try await replacementEntries().compactMap { e in e.replacement.map { (e.phrase, $0) } }
    }

    public func replacementEntries() async throws -> [DictionaryEntry] {
        try await list(kind: Kind.replacement).filter { $0.replacement != nil }
    }

    public func snippets() async throws -> [DictionaryEntry] { try await list(kind: Kind.snippet) }

    /// "Was -> became" pairs for the editor prompt (spec 3.4): freshest learned replacements first.
    public func editorExamples(limit: Int = 10) async throws -> [(before: String, after: String)] {
        try await writer.read { db in
            try DictionaryEntry.fetchAll(
                db,
                sql: """
                    SELECT * FROM dictionary_entry
                    WHERE deleted_at IS NULL AND kind = 'replacement' AND origin = 'learned' AND replacement IS NOT NULL
                    ORDER BY created_at DESC, rowid DESC LIMIT ?
                    """,
                arguments: [limit])
        }.compactMap { e in e.replacement.map { (e.phrase, $0) } }
    }

    /// Normalized (lowercase, ё = е) phrases of live words and replacements (triggers and targets): the "already known" set for `EditLearner`.
    public func knownPhrases() async throws -> Set<String> {
        let rows = try await writer.read { db in
            try DictionaryEntry.fetchAll(db, sql: "SELECT * FROM dictionary_entry WHERE deleted_at IS NULL AND kind != 'snippet'")
        }
        var out = Set<String>()
        for e in rows {
            out.insert(EditLearner.normalize(e.phrase))
            if e.kind == Kind.replacement, let r = e.replacement { out.insert(EditLearner.normalize(r)) }
        }
        return out
    }
}

fileprivate extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
