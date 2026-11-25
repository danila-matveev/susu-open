import Foundation
import GRDB
import SQLite3

/// Reading helpers for Wispr's flow.sqlite: schema-tolerant (spec 6, И7) and strictly read-only (И1).
enum WisprError: Error, Equatable {
    case sourceMissing(String)
    case snapshotFailed(String)
}

/// Safe value access by column name: a missing column or a value of an unexpected type gives nil.
struct WisprRow {
    let row: Row

    private func value(_ name: String) -> DatabaseValue? {
        row.hasColumn(name) ? (row[name] as DatabaseValue) : nil
    }
    func string(_ name: String) -> String? {
        guard let v = value(name), !v.isNull else { return nil }
        return String.fromDatabaseValue(v)
    }
    /// Non-empty text only.
    func text(_ name: String) -> String? {
        guard let s = string(name), !s.isEmpty else { return nil }
        return s
    }
    func int(_ name: String) -> Int? {
        guard let v = value(name), !v.isNull else { return nil }
        return Int.fromDatabaseValue(v)
    }
    func double(_ name: String) -> Double? {
        guard let v = value(name), !v.isNull else { return nil }
        return Double.fromDatabaseValue(v)
    }
    func bool(_ name: String) -> Bool {
        guard let v = value(name), !v.isNull else { return false }
        if let i = Int.fromDatabaseValue(v) { return i != 0 }
        return false
    }
    func date(_ name: String) -> Date? {
        guard let v = value(name), !v.isNull else { return nil }
        return WisprTime.parse(v)
    }
    func data(_ name: String) -> Data? {
        guard let v = value(name), !v.isNull else { return nil }
        return Data.fromDatabaseValue(v)
    }
}

enum WisprTime {
    /// Accepts `2026-08-04 09:48:11.864 +00:00`, ISO `...T...Z`, and Unix seconds/milliseconds as numbers.
    static func parse(_ v: DatabaseValue) -> Date? {
        switch v.storage {
        case .int64(let i): return fromNumber(Double(i))
        case .double(let d): return fromNumber(d)
        case .string(let s): return parse(s)
        default: return nil
        }
    }

    static func fromNumber(_ n: Double) -> Date? {
        guard n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
    }

    static func parse(_ s: String) -> Date? {
        let b = Array(s.utf8)
        guard b.count >= 19, b[4] == 45, b[7] == 45, b[10] == 32 || b[10] == 84, b[13] == 58, b[16] == 58 else {
            if let d = Double(s) { return fromNumber(d) }
            return nil
        }
        var i = 19
        var fraction = "000"
        if i < b.count, b[i] == 46 {
            var digits = ""
            i += 1
            while i < b.count, b[i] >= 48, b[i] <= 57 { digits.append(Character(UnicodeScalar(b[i]))); i += 1 }
            fraction = String((digits + "000").prefix(3))
        }
        var offsetSeconds = 0
        while i < b.count, b[i] == 32 { i += 1 }
        if i < b.count, b[i] == 43 || b[i] == 45 {
            let sign = b[i] == 45 ? -1 : 1
            let rest = String(decoding: b[(i + 1)...], as: UTF8.self).replacingOccurrences(of: ":", with: "")
            if rest.count >= 2, let h = Int(rest.prefix(2)) {
                let m = rest.count >= 4 ? (Int(rest.dropFirst(2).prefix(2)) ?? 0) : 0
                offsetSeconds = sign * (h * 3600 + m * 60)
            }
        }
        let head = String(decoding: b[0..<10], as: UTF8.self) + "T" + String(decoding: b[11..<19], as: UTF8.self)
        guard let base = SusuTime.date(head + "." + fraction + "Z") else { return nil }
        return base.addingTimeInterval(-Double(offsetSeconds))
    }
}

/// Read-only view of the snapshot database.
struct WisprSource {
    let queue: DatabaseQueue

    init(snapshot: URL) throws {
        var config = Configuration()
        config.readonly = true
        queue = try DatabaseQueue(path: snapshot.path, configuration: config)
    }

    /// Column names of a table, nil when the table does not exist.
    func columns(of table: String) throws -> Set<String>? {
        try queue.read { db in
            guard try db.tableExists(table) else { return nil }
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(Self.quote(table)))")
            return Set(rows.compactMap { $0["name"] as String? })
        }
    }

    static func quote(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}

/// What the importer needs from one Wispr table and what is actually there.
struct WisprTable {
    let name: String
    let idColumn: String
    let present: [String]
    let missing: [String]

    /// nil when the table or its id column does not exist (the step is skipped).
    static func inspect(_ name: String, idColumn: String, wanted: [String], in source: WisprSource) throws -> WisprTable? {
        guard let cols = try source.columns(of: name), cols.contains(idColumn) else { return nil }
        return WisprTable(name: name, idColumn: idColumn,
                          present: wanted.filter { cols.contains($0) }, missing: wanted.filter { !cols.contains($0) })
    }

    func count(in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(WisprSource.quote(name))") ?? 0
    }

    /// Next batch after `lastId`, ordered by id (keyset paging: also the resume checkpoint).
    func batch(_ db: Database, after lastId: String?, limit: Int) throws -> [WisprRow] {
        // Blobs (audio) are read one row at a time, never in a batch.
        let cols = ([idColumn] + present.filter { $0 != "audio" }).map(WisprSource.quote).joined(separator: ", ")
        let q = WisprSource.quote(idColumn)
        var sql = "SELECT \(cols) FROM \(WisprSource.quote(name))"
        var args = StatementArguments()
        if let lastId { sql += " WHERE \(q) > ?"; args = [lastId] }
        sql += " ORDER BY \(q) LIMIT \(limit)"
        return try Row.fetchAll(db, sql: sql, arguments: args).map(WisprRow.init)
    }
}

enum WisprSnapshot {
    /// Copies the Wispr database into `destination` with the SQLite Online Backup API.
    /// The source is opened read-only (`mode=ro`). SQLite would create a missing `-shm` file for a WAL database,
    /// so unless both `-wal` and `-shm` already exist (Wispr is running) it is opened `immutable=1` instead:
    /// nothing can be created in the Wispr folder (И1). Returns true when a leftover `-wal` had to be ignored.
    @discardableResult
    static func make(from source: URL, to destination: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: source.path) else { throw WisprError.sourceMissing(source.path) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        removeFiles(of: destination)

        let fm = FileManager.default
        let walExists = fm.fileExists(atPath: source.path + "-wal")
        let live = walExists && fm.fileExists(atPath: source.path + "-shm")
        var comps = URLComponents()
        comps.scheme = "file"
        comps.path = source.path
        comps.queryItems = [URLQueryItem(name: "mode", value: "ro")] + (live ? [] : [URLQueryItem(name: "immutable", value: "1")])
        guard let uri = comps.string else { throw WisprError.snapshotFailed("bad uri") }

        do {
            var src: OpaquePointer?
            guard sqlite3_open_v2(uri, &src, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let src else {
                let msg = src.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
                sqlite3_close(src)
                throw WisprError.snapshotFailed(msg)
            }
            defer { sqlite3_close(src) }
            var dst: OpaquePointer?
            guard sqlite3_open_v2(destination.path, &dst, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let dst else {
                sqlite3_close(dst)
                throw WisprError.snapshotFailed("cannot create snapshot")
            }
            defer { sqlite3_close(dst) }
            guard let backup = sqlite3_backup_init(dst, "main", src, "main") else {
                throw WisprError.snapshotFailed(String(cString: sqlite3_errmsg(dst)))
            }
            // One step = one read transaction on the source, so the copy is consistent while Wispr keeps writing.
            let rc = sqlite3_backup_step(backup, -1)
            sqlite3_backup_finish(backup)
            guard rc == SQLITE_DONE else { throw WisprError.snapshotFailed("backup step failed (\(rc))") }
            // The copy inherits Wispr's WAL mode; a read-only reader cannot open a WAL file without `-shm`.
            // The snapshot is ours, so switch it to a plain rollback journal.
            guard sqlite3_exec(dst, "PRAGMA journal_mode = DELETE", nil, nil, nil) == SQLITE_OK else {
                throw WisprError.snapshotFailed("cannot finalize snapshot")
            }
        } catch {
            removeFiles(of: destination)
            throw error
        }
        // Connections are closed here; drop the helper files SQLite left next to our own copy.
        for suffix in ["-shm", "-wal"] { try? fm.removeItem(atPath: destination.path + suffix) }
        return walExists && !live
    }

    static func removeFiles(of database: URL) {
        for suffix in ["", "-shm", "-wal", "-journal"] { try? FileManager.default.removeItem(atPath: database.path + suffix) }
    }
}
