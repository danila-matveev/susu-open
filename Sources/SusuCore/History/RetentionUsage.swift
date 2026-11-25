// «Занято на маке» (spec 1.6): bytes used by each kind of data in the data folder.
import Foundation

public struct DataUsage: Sendable, Equatable {
    public var dictationAudio: Int64
    public var callAudio: Int64
    public var database: Int64
    public var models: Int64
    public var total: Int64 { dictationAudio + callAudio + database + models }

    public init(dictationAudio: Int64 = 0, callAudio: Int64 = 0, database: Int64 = 0, models: Int64 = 0) {
        self.dictationAudio = dictationAudio; self.callAudio = callAudio; self.database = database; self.models = models
    }

    /// Folder layout is spec 5.1: `audio/` (dictations, notes), `calls/`, `susu.sqlite*`, `models/`.
    public static func measure(in directory: URL) -> DataUsage {
        let fm = FileManager.default
        var db: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let attrs = try? fm.attributesOfItem(atPath: directory.appendingPathComponent("susu.sqlite" + suffix).path)
            db += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return DataUsage(
            dictationAudio: folderSize(directory.appendingPathComponent("audio")),
            callAudio: folderSize(directory.appendingPathComponent("calls")),
            database: db,
            models: folderSize(directory.appendingPathComponent("models")))
    }

    static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            let v = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }
}
