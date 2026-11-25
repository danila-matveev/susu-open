import Foundation
import Testing
@testable import SusuCore

@Suite struct StyleResolverTests {
    // Defaults as seeded, in memory (ids are stable: "style-code", ...).
    static let seeded = StyleDefaults.make()

    static func pick(bundle: String? = nil, title: String? = nil, url: String? = nil,
                     styles: [Style] = seeded.styles, rules: [StyleRule] = seeded.rules) -> String {
        let ctx = ContextSnapshot(bundleID: bundle, windowTitle: title, url: url)
        return StyleResolver.resolve(context: ctx, styles: styles, rules: rules).id
    }

    struct Case: Sendable { let name: String; let bundle: String?; let title: String?; let url: String?; let expect: String }

    static let cases: [Case] = [
        .init(name: "VS Code", bundle: "com.microsoft.VSCode", title: nil, url: nil, expect: "style-code"),
        .init(name: "Cursor", bundle: "com.todesktop.230313mzl4w4u92", title: nil, url: nil, expect: "style-code"),
        .init(name: "iTerm", bundle: "com.googlecode.iterm2", title: nil, url: nil, expect: "style-code"),
        .init(name: "Telegram", bundle: "ru.keepcoder.Telegram", title: "Chat", url: nil, expect: "style-messengers"),
        .init(name: "WhatsApp", bundle: "net.whatsapp.WhatsApp", title: nil, url: nil, expect: "style-messengers"),
        .init(name: "Mail", bundle: "com.apple.mail", title: nil, url: nil, expect: "style-mail"),
        .init(name: "Spark", bundle: "com.readdle.SparkDesktop", title: nil, url: nil, expect: "style-mail"),
        .init(name: "Notion", bundle: "notion.id", title: nil, url: nil, expect: "style-tasks"),
        .init(name: "Notes", bundle: "com.apple.Notes", title: nil, url: nil, expect: "style-tasks"),
        .init(name: "Bitrix in Chrome", bundle: "com.google.Chrome", title: "Задачи", url: "https://acme.bitrix24.ru/company/personal/", expect: "style-tasks"),
        .init(name: "Gmail in Chrome", bundle: "com.google.Chrome", title: "Входящие", url: "https://mail.google.com/mail/u/0/#inbox", expect: "style-mail"),
        .init(name: "Gmail no path", bundle: "com.google.Chrome", title: nil, url: "mail.google.com", expect: "style-mail"),
        .init(name: "Gmail uppercase", bundle: "com.google.Chrome", title: nil, url: "HTTPS://Mail.Google.com/mail", expect: "style-mail"),
        .init(name: "Other site in Chrome", bundle: "com.google.Chrome", title: "News", url: "https://example.com/a", expect: "style-other"),
        .init(name: "Unknown app", bundle: "com.unknown.App", title: nil, url: nil, expect: "style-other"),
        .init(name: "Bitrix lookalike host", bundle: "com.google.Chrome", title: nil, url: "https://bitrix24.evil.com/x", expect: "style-other"),
    ]

    @Test(arguments: cases) func tableOfChoices(c: Case) {
        #expect(Self.pick(bundle: c.bundle, title: c.title, url: c.url) == c.expect, "\(c.name)")
    }

    @Test func nilContextGivesDefault() {
        #expect(StyleResolver.resolve(context: nil, styles: Self.seeded.styles, rules: Self.seeded.rules).id == "style-other")
    }

    @Test func urlBeatsTitleBeatsBundle() {
        let a = Style(id: "a", name: "A", sort: 1), b = Style(id: "b", name: "B", sort: 2)
        let c = Style(id: "c", name: "C", sort: 3), d = Style(id: "d", name: "D", isDefault: true, sort: 4)
        let rules = [
            StyleRule(styleId: "a", kind: "bundle", pattern: "com.x.App"),
            StyleRule(styleId: "b", kind: "title", pattern: "Report"),
            StyleRule(styleId: "c", kind: "url", pattern: "*.site.com/*"),
        ]
        let styles = [a, b, c, d]
        #expect(Self.pick(bundle: "com.x.App", styles: styles, rules: rules) == "a")
        #expect(Self.pick(bundle: "com.x.App", title: "Quarterly report", styles: styles, rules: rules) == "b")
        #expect(Self.pick(bundle: "com.x.App", title: "Quarterly report", url: "https://my.site.com/p", styles: styles, rules: rules) == "c")
    }

    @Test func titleRuleBeatsBundleInSameApp() {
        let styles = [Style(id: "chat", name: "Chat", sort: 1), Style(id: "work", name: "Work", sort: 2),
                      Style(id: "def", name: "Def", isDefault: true, sort: 3)]
        let rules = [StyleRule(styleId: "chat", kind: "bundle", pattern: "ru.keepcoder.Telegram"),
                     StyleRule(styleId: "work", kind: "title", pattern: "Lumera team")]
        #expect(Self.pick(bundle: "ru.keepcoder.Telegram", title: "LUMERA TEAM chat", styles: styles, rules: rules) == "work")
        #expect(Self.pick(bundle: "ru.keepcoder.Telegram", title: "Mom", styles: styles, rules: rules) == "chat")
    }

    @Test func tieBrokenByPriorityThenStyleSort() {
        let styles = [Style(id: "s1", name: "S1", sort: 1), Style(id: "s2", name: "S2", sort: 2),
                      Style(id: "def", name: "Def", isDefault: true, sort: 9)]
        let sameBundle = [StyleRule(styleId: "s1", kind: "bundle", pattern: "com.x", priority: 0),
                          StyleRule(styleId: "s2", kind: "bundle", pattern: "com.x", priority: 5)]
        #expect(Self.pick(bundle: "com.x", styles: styles, rules: sameBundle) == "s2")
        let equal = [StyleRule(styleId: "s2", kind: "bundle", pattern: "com.x"),
                     StyleRule(styleId: "s1", kind: "bundle", pattern: "com.x")]
        #expect(Self.pick(bundle: "com.x", styles: styles, rules: equal) == "s1")
    }

    @Test func deletedStylesAndRulesAreIgnored() {
        var gone = Style(id: "gone", name: "Gone", sort: 1); gone.deletedAt = Date()
        let def = Style(id: "def", name: "Def", isDefault: true, sort: 2)
        let live = Style(id: "live", name: "Live", sort: 3)
        var deadRule = StyleRule(styleId: "live", kind: "bundle", pattern: "com.x"); deadRule.deletedAt = Date()
        let rules = [StyleRule(styleId: "gone", kind: "bundle", pattern: "com.x"), deadRule]
        #expect(Self.pick(bundle: "com.x", styles: [gone, def, live], rules: rules) == "def")
    }

    @Test func noDefaultFallsBackToFirstStyleOrBuiltIn() {
        let s = [Style(id: "z", name: "Z", sort: 2), Style(id: "y", name: "Y", sort: 1)]
        #expect(Self.pick(styles: s, rules: []) == "y")
        let none = StyleResolver.resolve(context: nil, styles: [], rules: [])
        #expect(none.cleanupLevel == "normal")
    }

    @Test func globMatching() {
        #expect(StyleResolver.globMatches("*.bitrix24.*/*", "a.bitrix24.ru/x"))
        #expect(!StyleResolver.globMatches("*.bitrix24.*/*", "bitrix24.ru/x"))
        #expect(StyleResolver.globMatches("mail.google.com/*", "mail.google.com/"))
        #expect(!StyleResolver.globMatches("mail.google.com/*", "xmail.google.com/a"))
        #expect(StyleResolver.globMatches("a*b*c", "aXXbYYc"))
        #expect(!StyleResolver.globMatches("a*b", "abc"))
    }
}
