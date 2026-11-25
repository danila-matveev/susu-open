// «Выгрузить всё» (spec 1.6): one zip with the database, audio and settings. Never contains API keys:
// keys live only in the Keychain, and secret-looking fields are also dropped from the settings copy.
import Foundation
import GRDB

public enum DataExportError: Error, Equatable {
    case unsupportedPlatform
    case zipFailed(String)
}

public struct DataExporter: Sendable {
    public let directory: URL
    public let database: SusuDatabase

    public init(directory: URL, database: SusuDatabase) {
        self.directory = directory
        self.database = database
    }

    /// Writes the zip to `zipURL` (replacing a file that is already there). Runs synchronously: call off the main thread.
    public func export(to zipURL: URL) throws {
        #if os(macOS)
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("susu-export-\(UUID().uuidString)", isDirectory: true)
        let root = staging.appendingPathComponent("Susu-export", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // Exact page copy through SQLite's backup API (VACUUM would renumber rowids and break the FTS indexes).
        let copy = try DatabaseQueue(path: root.appendingPathComponent("susu.sqlite").path)
        try database.writer.backup(to: copy)
        try copy.close()

        try Self.writeSettingsCopy(from: directory.appendingPathComponent(SettingsStore.fileName),
                                   to: root.appendingPathComponent(SettingsStore.fileName))
        for folder in ["audio", "calls"] {
            let src = directory.appendingPathComponent(folder)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: root.appendingPathComponent(folder)) }
        }

        try? fm.removeItem(at: zipURL)
        try Self.zip(folder: root, to: zipURL)
        #else
        throw DataExportError.unsupportedPlatform
        #endif
    }

    /// Top-level fields that look like secrets are removed (defence in depth; the model has none).
    static func writeSettingsCopy(from source: URL, to target: URL) throws {
        guard let data = try? Data(contentsOf: source),
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for key in object.keys where ["key", "token", "secret", "password"].contains(where: { key.lowercased().contains($0) }) {
            object[key] = nil
        }
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: target)
    }

    #if os(macOS)
    private static func zip(folder: URL, to zipURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", folder.path, zipURL.path]
        let err = Pipe()
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw DataExportError.zipFailed(text)
        }
    }
    #endif
}
