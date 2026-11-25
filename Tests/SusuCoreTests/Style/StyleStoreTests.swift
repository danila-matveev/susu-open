import Foundation
import Testing
@testable import SusuCore

@Suite struct StyleStoreTests {
    func makeStore() throws -> StyleStore { StyleStore(database: try SusuDatabase.inMemory()) }

    @Test func seedCreatesFiveStylesOnce() async throws {
        let store = try makeStore()
        try await store.seedDefaultsIfEmpty()
        try await store.seedDefaultsIfEmpty()
        let styles = try await store.styles()
        let rules = try await store.rules()
        #expect(styles.map(\.name) == ["Код", "Мессенджеры", "Почта", "Задачи и заметки", "Прочее"])
        #expect(styles.filter(\.isDefault).map(\.name) == ["Прочее"])
        #expect(rules.count == StyleDefaults.make().rules.count)
        let code = try #require(styles.first { $0.name == "Код" })
        #expect(code.cleanupLevel == "names" && !code.voiceCommands && !code.prompt.isEmpty)
        #expect(styles.first { $0.name == "Почта" }?.cleanupLevel == "careful")
    }

    @Test func seedSkippedWhenUserAlreadyHasStyles() async throws {
        let store = try makeStore()
        try await store.save(style: Style(id: "mine", name: "Мой", isDefault: true))
        try await store.seedDefaultsIfEmpty()
        #expect(try await store.styles().count == 1)
    }

    @Test func seedNotRepeatedAfterUserDeletedEverything() async throws {
        let store = try makeStore()
        try await store.seedDefaultsIfEmpty()
        for s in try await store.styles() where !s.isDefault { try await store.delete(styleId: s.id) }
        try await store.seedDefaultsIfEmpty()
        #expect(try await store.styles().count == 1)
    }

    @Test func resolveFromSeededStore() async throws {
        let store = try makeStore()
        try await store.seedDefaultsIfEmpty()
        let ctx = ContextSnapshot(bundleID: "com.google.Chrome", url: "https://x.bitrix24.ru/y")
        let style = StyleResolver.resolve(context: ctx, styles: try await store.styles(), rules: try await store.rules())
        #expect(style.name == "Задачи и заметки")
    }

    @Test func saveRuleAndDeleteStyleCascadesSoftly() async throws {
        let store = try makeStore()
        try await store.save(style: Style(id: "a", name: "A", sort: 1))
        try await store.save(rule: StyleRule(id: "r", styleId: "a", kind: "bundle", pattern: "com.x"))
        #expect(try await store.rules(styleId: "a").count == 1)
        try await store.delete(ruleId: "r")
        #expect(try await store.rules().isEmpty)
        try await store.save(rule: StyleRule(id: "r2", styleId: "a", kind: "title", pattern: "t"))
        try await store.delete(styleId: "a")
        #expect(try await store.styles().isEmpty)
        #expect(try await store.rules().isEmpty)
    }

    @Test func editedPromptPersists() async throws {
        let store = try makeStore()
        try await store.seedDefaultsIfEmpty()
        var s = try #require(try await store.styles().first)
        s.prompt = "Новое правило"
        try await store.save(style: s)
        #expect(try await store.styles().first?.prompt == "Новое правило")
    }

    @Test func onlyOneDefaultAfterSettingAnother() async throws {
        let store = try makeStore()
        try await store.seedDefaultsIfEmpty()
        var mail = try #require(try await store.styles().first { $0.name == "Почта" })
        mail.isDefault = true
        try await store.save(style: mail)
        #expect(try await store.styles().filter(\.isDefault).map(\.name) == ["Почта"])
    }
}
