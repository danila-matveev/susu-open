import Foundation
import SusuCore

/// Exports the user's Wispr dictionary for the editor bench, through the real importer
/// (it snapshots the Wispr database read-only; everything else happens in a temp Susu database).
/// Writes `{"words": [...], "replacements": [{"phrase", "replacement"}]}`.
enum WisprDictionaryCommand {
    static func run(_ a: [String]) async {
        var out: String?
        var folder: URL?
        var i = 0
        while i < a.count {
            switch a[i] {
            case "--out": i += 1; out = i < a.count ? a[i] : nil
            case "--wispr-folder": i += 1; folder = i < a.count ? URL(fileURLWithPath: a[i]) : nil
            default: TranscribeCommand.fail("unknown argument \(a[i])")
            }
            i += 1
        }
        guard let out else { TranscribeCommand.fail("usage: susu-bench wispr-dictionary --out FILE") }
        do {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("susu-bench-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let db = try SusuDatabase(url: temp.appendingPathComponent("susu.sqlite"))
            let importer = WisprImporter(database: db, dataDirectory: temp, wisprFolder: try folder ?? WisprImporter.defaultWisprFolder())
            let report = try await importer.run(includeAudio: false)
            if let step = report.step("Dictionary") { print("Dictionary step: found \(step.total), imported \(step.imported), skipped \(step.skipped)") }
            let service = DictionaryService(database: db)
            let words = try await service.list(kind: DictionaryService.Kind.word).map(\.phrase)
            let replacements = try await service.replacements().map { ["phrase": $0.phrase, "replacement": $0.replacement] }
            let json: [String: Any] = ["words": words, "replacements": replacements]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: out))
            print("wrote \(out): \(words.count) words, \(replacements.count) replacements")
        } catch {
            TranscribeCommand.fail("\(error)")
        }
    }
}
