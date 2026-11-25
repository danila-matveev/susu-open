import CryptoKit
import Foundation
import SusuCore

/// Full Wispr import into a test Susu folder (M4 check on the real data, read-only for Wispr):
/// prints every step, then proves the Wispr folder did not change (И1: same files, sizes, times and hashes).
enum WisprImportCommand {
    static func run(_ a: [String]) async {
        var data: String?, folder: URL?, audio = false
        var i = 0
        while i < a.count {
            switch a[i] {
            case "--data": i += 1; data = i < a.count ? a[i] : nil
            case "--wispr-folder": i += 1; folder = i < a.count ? URL(fileURLWithPath: a[i]) : nil
            case "--audio": audio = true
            default: TranscribeCommand.fail("unknown argument \(a[i])")
            }
            i += 1
        }
        guard let data else { TranscribeCommand.fail("usage: susu-bench wispr-import --data DIR [--audio]") }
        do {
            let wispr = try folder ?? WisprImporter.defaultWisprFolder()
            let before = fingerprint(wispr)
            let dir = URL(fileURLWithPath: data, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let db = try SusuDatabase(url: dir.appendingPathComponent("susu.sqlite"))
            try await StyleStore(database: db).seedDefaultsIfEmpty()   // the app seeds them at launch
            let t0 = Date()
            let report = try await WisprImporter(database: db, dataDirectory: dir, wisprFolder: wispr).run(includeAudio: audio)
            print(String(format: "import took %.1f s", Date().timeIntervalSince(t0)))
            for s in report.steps {
                print("\(s.name): total \(s.total), imported \(s.imported), already \(s.alreadyImported), skipped \(s.skipped) \(s.skipReasons) \(s.details)\(s.note.map { " — \($0)" } ?? "")")
            }
            let after = fingerprint(wispr)
            print(before == after ? "И1 ok: Wispr folder unchanged (\(before.count) files)" : "И1 FAIL: Wispr folder changed")
            for p in Set(before.keys).union(after.keys).sorted() where before[p] != after[p] {
                print("  changed: \(p.replacingOccurrences(of: wispr.path, with: "…")) \(before[p] ?? "new") -> \(after[p] ?? "gone")")
            }
            if before != after { exit(1) }
        } catch {
            TranscribeCommand.fail("\(error)")
        }
    }

    /// path -> size|mtime|sha256 of the files the importer reads (sha only for files under 200 MB).
    static func fingerprint(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return out }
        for case let url as URL in e {
            // Only what the importer reads; the rest is Wispr's own Electron cache and telemetry, rewritten while it runs.
            let rel = String(url.path.dropFirst(root.path.count + 1))
            guard rel.hasPrefix("flow.sqlite") || rel == "config.json" || rel.hasPrefix("meetings/") else { continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let size = v.fileSize ?? 0
            var hash = ""
            if size < 200_000_000, let d = try? Data(contentsOf: url, options: .mappedIfSafe) {
                hash = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
            }
            out[url.path] = "\(size)|\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(hash)"
        }
        return out
    }
}
