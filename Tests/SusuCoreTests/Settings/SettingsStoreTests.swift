import Foundation
import Testing
@testable import SusuCore

@Suite struct SettingsStoreTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("susu-settings-\(UUID().uuidString)")
    }

    @Test func defaultsWhenFileMissing() {
        let s = SettingsStore(directory: tempDir()).current
        #expect(s.hotkeys.holdThreshold == 0.3)
        #expect(s.hotkeys.doubleTapWindow == 0.4)
        #expect(s.hotkeys.dictation == .modifier(.leftControl))
        #expect(s.audioRetentionDays == 90)
        #expect(!s.soundsEnabled)
        #expect(s.providers.dictation == ProviderChoice(providerID: .groq, model: "whisper-large-v3-turbo"))
        #expect(s.schemaVersion == Settings.currentSchemaVersion)
    }

    @Test func roundTrip() throws {
        let dir = tempDir()
        let store = SettingsStore(directory: dir)
        try store.update {
            $0.hotkeys.dictation = .modifier(.rightControl)
            $0.micPriority = ["uid-a", "uid-b"]
            $0.dictationLanguage = .ru
            $0.theme = .dark
            $0.providers.editor = ProviderChoice(providerID: .openRouter, model: "x/y", baseURL: "https://example.com/v1")
        }
        let loaded = SettingsStore(directory: dir).current
        #expect(loaded == store.current)
        #expect(loaded.hotkeys.dictation == .modifier(.rightControl))
        #expect(loaded.dictationLanguage.languageMode == .fixed("ru"))
        #expect(loaded.providers.editor?.baseURL == "https://example.com/v1")
    }

    @Test func unknownFieldsSurvive() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"schemaVersion":1,"futureThing":{"a":[1,2,{"b":null}],"c":"d"},"soundsEnabled":false}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("settings.json"))
        let store = SettingsStore(directory: dir)
        #expect(store.current.soundsEnabled == false)
        try store.update { $0.launchAtLogin = true }
        let raw = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: dir.appendingPathComponent("settings.json")))
        #expect(raw["futureThing"] == .object(["a": .array([.number(1), .number(2), .object(["b": .null])]), "c": .string("d")]))
        #expect(raw["launchAtLogin"] == .bool(true))
    }

    @Test func partialFileFillsDefaults() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"hotkeys":{"holdThreshold":0.5}}"#.utf8).write(to: dir.appendingPathComponent("settings.json"))
        let s = SettingsStore(directory: dir).current
        #expect(s.hotkeys.holdThreshold == 0.5)
        #expect(s.hotkeys.doubleTapWindow == 0.4)
        #expect(s.providers.dictation?.providerID == .groq)
    }

    @Test func corruptFileGivesDefaultsAndBackup() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("settings.json"))
        let s = SettingsStore(directory: dir).current
        #expect(s == Settings())
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.contains { $0.hasPrefix("settings.corrupt-") })
        #expect(!files.contains("settings.json"))
    }

    @Test func envOverridesDataFolder() {
        let url = SettingsStore.defaultDirectory(environment: ["SUSU_DATA_DIR": "/tmp/susu-x"])
        #expect(url.path == "/tmp/susu-x")
    }

    @Test func changesAreDelivered() async throws {
        let store = SettingsStore(directory: tempDir())
        var iterator = store.changes().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.theme == .system)
        try store.update { $0.theme = .light }
        let second = await iterator.next()
        #expect(second?.theme == .light)
    }
}
