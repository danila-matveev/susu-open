// Notes on top of the `note` table (spec 1.6 «Заметки», 5.2): create, edit, soft delete with undo, search, tag filter.
import Foundation
import GRDB

extension Note {
    /// Tags as a list; stored as a JSON array in `tags_json` (nil when empty).
    public var tags: [String] {
        get {
            guard let data = tagsJson?.data(using: .utf8),
                  let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return list
        }
        set {
            guard !newValue.isEmpty, let data = try? JSONEncoder().encode(newValue) else { tagsJson = nil; return }
            tagsJson = String(data: data, encoding: .utf8)
        }
    }

    /// First sentence-ish line of the text, for list rows.
    public var firstLine: String {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let line = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if let end = line.firstIndex(where: { ".!?".contains($0) }) {
            let after = line.index(after: end)
            if after == line.endIndex || line[after].isWhitespace { return String(line[...end]) }
        }
        return line
    }
}

public final class NotesStore: Sendable {
    let database: SusuDatabase
    /// Base for relative `audioPath` values (normally the data folder).
    public let baseDirectory: URL?

    public init(database: SusuDatabase, baseDirectory: URL? = nil) {
        self.database = database
        self.baseDirectory = baseDirectory
    }

    private var writer: any DatabaseWriter { database.writer }

    // MARK: Write

    /// Inserts a new note and returns it.
    @discardableResult
    public func create(title: String? = nil, text: String? = nil, tags: [String] = [], audioPath: String? = nil,
                       origin: String = "manual", source: String? = nil, sourceId: String? = nil,
                       now: Date = Date()) async throws -> Note {
        var note = Note(createdAt: now, title: title, text: text, audioPath: audioPath, origin: origin,
                        source: source, sourceId: sourceId)
        note.tags = tags
        try await writer.write { [note] db in try note.insert(db) }
        return note
    }

    /// Reads, mutates and writes back in one transaction. nil if the note is missing or deleted.
    @discardableResult
    public func update(id: String, _ mutate: @Sendable (inout Note) -> Void) async throws -> Note? {
        try await writer.write { db in
            guard var n = try Note.fetchOne(db, key: id), n.deletedAt == nil else { return nil }
            mutate(&n)
            n.id = id
            try n.update(db)
            return try Note.fetchOne(db, key: id)
        }
    }

    /// Hides the note from list and search. The audio stays until `purge`, so Undo works.
    public func softDelete(id: String, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE note SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL",
                           arguments: [SusuTime.string(now), id])
        }
    }

    /// Undo of `softDelete`.
    public func restore(id: String) async throws {
        try await writer.write { db in try db.execute(sql: "UPDATE note SET deleted_at = NULL WHERE id = ?", arguments: [id]) }
    }

    // MARK: Read

    public func fetch(id: String) async throws -> Note? {
        try await writer.read { db in
            try Note.fetchOne(db, sql: "SELECT * FROM note WHERE id = ? AND deleted_at IS NULL", arguments: [id])
        }
    }

    /// Newest first. `tag` keeps only notes that carry exactly that tag.
    public func list(tag: String? = nil, limit: Int = 500) async throws -> [Note] {
        try await writer.read { db in try Self.fetchList(db, tag: tag, limit: limit) }
    }

    /// Full-text search over title and text (every word is a prefix), newest first.
    public func search(_ query: String, tag: String? = nil, limit: Int = 500) async throws -> [Note] {
        try await writer.read { db in try Self.fetchSearch(db, query: query, tag: tag, limit: limit) }
    }

    /// Every tag in use by live notes, most used first.
    public func allTags() async throws -> [String] {
        try await writer.read { db in try Self.fetchTags(db) }
    }

    // MARK: Observe (for the UI)

    public func observeNotes(limit: Int = 500) -> AsyncValueObservation<[Note]> {
        ValueObservation.tracking { db in try Self.fetchList(db, tag: nil, limit: limit) }.values(in: writer)
    }

    // MARK: Audio

    /// Absolute URL of the note's audio file if it still exists.
    public func audioURL(for note: Note) -> URL? {
        guard let path = note.audioPath, !path.isEmpty else { return nil }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : baseDirectory?.appendingPathComponent(path)
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: Titles

    /// Fills the title and tags of a freshly saved note with one short request, unless the user already
    /// changed the title meanwhile. Never throws on model trouble: the fallback title stays.
    @discardableResult
    public func autoTitle(id: String, titler: NoteTitler) async throws -> Note? {
        guard let note = try await fetch(id: id), let text = note.text, !text.isEmpty else { return nil }
        let before = note.title
        let result = await titler.title(for: text)
        return try await update(id: id) { n in
            guard n.title == before else { return }
            n.title = result.title
            if n.tags.isEmpty { n.tags = result.tags }
        }
    }

    // MARK: Queries

    private static func tagCondition(_ tag: String?, alias: String) -> (String, [any DatabaseValueConvertible]) {
        guard let tag else { return ("", []) }
        return (" AND EXISTS (SELECT 1 FROM json_each(\(alias).tags_json) WHERE value = ?)", [tag])
    }

    private static func fetchList(_ db: Database, tag: String?, limit: Int) throws -> [Note] {
        var (cond, args) = tagCondition(tag, alias: "n")
        args.append(limit)
        return try Note.fetchAll(
            db,
            sql: "SELECT n.* FROM note n WHERE n.deleted_at IS NULL\(cond) ORDER BY n.created_at DESC, n.id DESC LIMIT ?",
            arguments: StatementArguments(args))
    }

    private static func fetchSearch(_ db: Database, query: String, tag: String?, limit: Int) throws -> [Note] {
        guard let pattern = HistoryStore.ftsPattern(query) else { return [] }
        var (cond, args) = tagCondition(tag, alias: "n")
        args.insert(pattern, at: 0)
        args.append(limit)
        return try Note.fetchAll(
            db,
            sql: """
                SELECT n.* FROM note_fts JOIN note n ON n.rowid = note_fts.rowid
                WHERE note_fts MATCH ? AND n.deleted_at IS NULL\(cond)
                ORDER BY n.created_at DESC, n.id DESC LIMIT ?
                """,
            arguments: StatementArguments(args))
    }

    private static func fetchTags(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT j.value FROM note n, json_each(n.tags_json) j
            WHERE n.deleted_at IS NULL AND n.tags_json IS NOT NULL
            GROUP BY j.value ORDER BY COUNT(*) DESC, j.value
            """)
    }
}
