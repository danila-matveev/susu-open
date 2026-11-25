// One place that owns the data folder, the database and the stores built on it.
// The app creates it once; screens and the dictation path read it through ShellModel.services.
import Foundation

public final class AppServices: Sendable {
    public let dataDirectory: URL
    public let settings: SettingsStore
    public let database: SusuDatabase
    public let history: HistoryStore
    public let dictionary: DictionaryService
    public let styles: StyleStore
    public let secrets: SecretStore
    public let registry: ProviderRegistry
    public let spend: SpendLog

    /// `directory` defaults to `SUSU_DATA_DIR` or ~/Library/Application Support/Susu.
    public init(directory: URL = SettingsStore.defaultDirectory(), secrets: SecretStore = SecretStore()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dataDirectory = directory
        settings = SettingsStore(directory: directory)
        database = try SusuDatabase(url: directory.appendingPathComponent("susu.sqlite"))
        history = HistoryStore(database: database, baseDirectory: directory)
        dictionary = DictionaryService(database: database)
        styles = StyleStore(database: database)
        self.secrets = secrets
        registry = .builtIn
        spend = SpendLog(db: database, registry: registry)
    }

    /// Throwaway services in a temp folder: previews and tests.
    public static func temporary() -> AppServices {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("susu-preview-\(UUID().uuidString)")
        // ponytail: try! is fine here, a temp folder that cannot be created means the machine is broken.
        return try! AppServices(directory: dir)
    }
}
