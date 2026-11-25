// Reads and writes settings.json in the data folder (spec 5.1). Changes apply without restart.
import Foundation

public final class SettingsStore: @unchecked Sendable {
    public static let fileName = "settings.json"

    /// Data folder: `SUSU_DATA_DIR` if set (tests, E2E), else ~/Library/Application Support/Susu.
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["SUSU_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Susu", isDirectory: true)
    }

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    private let lock = NSLock()
    private var settings = Settings()
    private var continuations: [UUID: AsyncStream<Settings>.Continuation] = [:]

    public init(directory: URL = SettingsStore.defaultDirectory()) {
        self.directory = directory
        settings = loadFromDisk()
    }

    public var current: Settings {
        lock.lock(); defer { lock.unlock() }
        return settings
    }

    /// Applies `change`, saves atomically, then notifies subscribers.
    @discardableResult
    public func update(_ change: (inout Settings) -> Void) throws -> Settings {
        lock.lock()
        var next = settings
        change(&next)
        next.schemaVersion = Settings.currentSchemaVersion
        do {
            try write(next)
        } catch {
            lock.unlock()
            throw error
        }
        settings = next
        let listeners = Array(continuations.values)
        lock.unlock()
        for l in listeners { l.yield(next) }
        return next
    }

    /// Yields the current settings first, then every later change.
    public func changes() -> AsyncStream<Settings> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            let now = settings
            lock.unlock()
            continuation.yield(now)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    // MARK: - Disk

    /// Upgrade hook: bring a raw older file up to the current schema. Add steps per version here.
    static func migrate(_ raw: inout [String: JSONValue]) {
        var version: Int
        if case .number(let n)? = raw["schemaVersion"] { version = Int(n) } else { version = 0 }
        // Example for later: if version < 2 { ...rename fields...; version = 2 }
        if version < Settings.currentSchemaVersion { version = Settings.currentSchemaVersion }
        raw["schemaVersion"] = .number(Double(version))
    }

    private func loadFromDisk() -> Settings {
        guard let data = try? Data(contentsOf: fileURL) else { return Settings() }
        do {
            var raw = try JSONDecoder().decode([String: JSONValue].self, from: data)
            Self.migrate(&raw)
            let migrated = try JSONEncoder().encode(raw)
            return try JSONDecoder().decode(Settings.self, from: migrated)
        } catch {
            backUpCorruptFile()
            return Settings()
        }
    }

    private func backUpCorruptFile() {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = directory.appendingPathComponent("settings.corrupt-\(stamp).json")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }

    private func write(_ value: Settings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: fileURL, options: .atomic)
    }
}
