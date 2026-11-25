import Testing
@testable import SusuCore

@Suite struct ContextRulesTests {
    @Test func shortTextIsKept() {
        #expect(ContextRules.textBeforeCaret("hello world", caretUTF16: 5) == "hello")
    }

    @Test func trimsToLast500() {
        let s = String(repeating: "a", count: 300) + String(repeating: "b", count: 600)
        let r = ContextRules.textBeforeCaret(s, caretUTF16: 900)
        #expect(r.count == 500)
        #expect(r.hasSuffix("b"))
        #expect(!r.contains("a"))
    }

    @Test func caretClampedToText() {
        #expect(ContextRules.textBeforeCaret("abc", caretUTF16: 99) == "abc")
        #expect(ContextRules.textBeforeCaret("abc", caretUTF16: -4) == "")
    }

    @Test func emojiNeverCut() {
        let s = String(repeating: "👨‍👩‍👧", count: 600)
        let r = ContextRules.textBeforeCaret(s, caretUTF16: s.utf16.count)
        #expect(r.count == 500)
        #expect(r.allSatisfy { $0 == "👨‍👩‍👧" })
    }

    @Test func caretInsideSurrogatePairMovesBack() {
        let s = "ab😀cd"  // utf16: a b [D83D DE00] c d; offset 3 is inside the pair
        #expect(ContextRules.textBeforeCaret(s, caretUTF16: 3) == "ab")
        #expect(ContextRules.textBeforeCaret(s, caretUTF16: 4) == "ab😀")
    }

    @Test func caretInsideEmojiSequenceMovesBack() {
        let s = "a👨‍👩‍👧b"
        #expect(ContextRules.textBeforeCaret(s, caretUTF16: 4) == "a")
    }

    @Test func fetchedTailDropsBrokenLead() {
        let s = "\u{FFFD}" + "tail"
        #expect(ContextRules.trimFetchedTail(s) == "tail")
    }

    @Test func cyrillicAndMixed() {
        let s = "Привет, мир 🌍 test"
        #expect(ContextRules.textBeforeCaret(s, caretUTF16: s.utf16.count) == s)
    }

    @Test func exclusions() {
        #expect(ContextRules.isExcluded(bundleID: "com.1password.1password", exclusions: ContextRules.defaultExclusions))
        #expect(ContextRules.isExcluded(bundleID: "com.apple.keychainaccess", exclusions: ContextRules.defaultExclusions))
        #expect(!ContextRules.isExcluded(bundleID: "com.apple.TextEdit", exclusions: ContextRules.defaultExclusions))
        #expect(!ContextRules.isExcluded(bundleID: nil, exclusions: ContextRules.defaultExclusions))
        #expect(ContextRules.isExcluded(bundleID: "x.y", exclusions: ["x.y"]))
    }

    @Test(arguments: [
        ("https://mail.google.com/mail/u/0/#inbox", "mail.google.com/mail/u/0/"),
        ("http://Example.COM/Path/Page?q=1&b=2", "example.com/Path/Page"),
        ("https://user:pw@host.io/a", "host.io/a"),
        ("https://team.bitrix24.ru", "team.bitrix24.ru"),
        ("mail.google.com/mail", "mail.google.com/mail"),
        ("localhost:3000/app", "localhost:3000/app"),
    ])
    func urlNormalization(input: String, expected: String) {
        #expect(ContextRules.normalizeURL(input) == expected)
    }

    @Test(arguments: ["", "   ", "about:blank", "chrome://settings", "file:///Users/x/a.html", "mailto:a@b.c"])
    func nonWebURLsRejected(input: String) {
        #expect(ContextRules.normalizeURL(input) == nil)
    }

    @Test func sameTarget() {
        let a = ContextSnapshot(pid: 10, focusedElementID: "x")
        #expect(ContextRules.isSameTarget(a, ContextSnapshot(pid: 10, focusedElementID: "x")))
        #expect(!ContextRules.isSameTarget(a, ContextSnapshot(pid: 10, focusedElementID: "y")))
        #expect(!ContextRules.isSameTarget(a, ContextSnapshot(pid: 11, focusedElementID: "x")))
        #expect(ContextRules.isSameTarget(a, ContextSnapshot(pid: 10, focusedElementID: nil)))
        #expect(ContextRules.isSameTarget(ContextSnapshot(pid: 10), ContextSnapshot(pid: 10)))
        #expect(!ContextRules.isSameTarget(ContextSnapshot(pid: nil), ContextSnapshot(pid: 10)))
    }
}
