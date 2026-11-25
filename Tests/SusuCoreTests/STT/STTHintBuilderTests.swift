import Testing
@testable import SusuCore

@Suite struct STTHintBuilderTests {
    @Test func orderIsStarredThenUseCountThenTitleWords() {
        let h = STTHintBuilder.build(terms: [
            HintTerm("Alpha", useCount: 5), HintTerm("Beta", starred: true, useCount: 1),
            HintTerm("Gamma", useCount: 9), HintTerm("Delta", starred: true, useCount: 7),
        ], windowTitle: "Lumera dashboard - Chrome")
        #expect(h.terms == ["Delta", "Beta", "Gamma", "Alpha", "Lumera", "dashboard", "Chrome"])
        #expect(h.prompt == "Delta, Beta, Gamma, Alpha, Lumera, dashboard, Chrome")
    }

    @Test func noWrapperWordsJustCommaSeparatedTerms() {
        let h = STTHintBuilder.build(terms: [HintTerm("Claude Code"), HintTerm("Битрикс")])
        #expect(h.prompt == "Claude Code, Битрикс")
        #expect(!h.prompt.contains(":"))
    }

    @Test func stopsAtTokenBudgetKeepingRankOrder() {
        func name(_ i: Int) -> String {   // far apart in spelling: no near-duplicate or sound-alike drops
            let l = Array("abcdefghijklmnopqrstuvwxyz")
            return String([l[i / 26], l[i % 26], l[(i * 7) % 26], l[(i * 3 + 1) % 26]]) + "qwzxy"
        }
        let many = (0..<200).map { HintTerm(name($0), useCount: 1000 - $0) }
        let h = STTHintBuilder.build(terms: many)
        let cost = h.terms.map(STTHintBuilder.estimatedTokens).reduce(0, +)
        #expect(cost <= STTHintBuilder.maxTokens)
        #expect(h.terms.first == name(0))
        #expect(h.terms.count < 200 && h.terms.count > 10)
    }

    @Test func cyrillicCostsMoreThanLatin() {
        #expect(STTHintBuilder.estimatedTokens("Битрикс") > STTHintBuilder.estimatedTokens("Bitrix"))
        #expect(STTHintBuilder.estimatedTokens("InboxKit") == 4)   // ceil(8/3) + separator
    }

    @Test func dropsDuplicatesNearDuplicatesAndGenericTerms() {
        let h = STTHintBuilder.build(terms: [
            HintTerm("Telega.in", useCount: 9), HintTerm("telega.in", useCount: 8), HintTerm("Telega", useCount: 7),
            HintTerm("Whisper", useCount: 6), HintTerm("Whispr", useCount: 5),
            HintTerm("the", useCount: 4), HintTerm("12", useCount: 3), HintTerm("A", useCount: 2),
            HintTerm("Groq", useCount: 1),
        ])
        #expect(h.terms == ["Telega.in", "Whisper", "Groq"])
    }

    @Test func titleWordsSkipShortAndNumeric() {
        let h = STTHintBuilder.build(terms: [], windowTitle: "PR #1234 — fix Telega.in on ok")
        #expect(h.terms == ["fix", "Telega.in"])
    }

    @Test func soundAlikeTermsAreDroppedUnlessStarred() {
        let terms = [HintTerm("TELOWAY", useCount: 9), HintTerm("Telega.in", useCount: 5),
                     HintTerm("Telegram", useCount: 3), HintTerm("Groq", useCount: 1)]
        #expect(STTHintBuilder.build(terms: terms).terms == ["Groq"])
        let starred = [HintTerm("TELOWAY", starred: true)] + terms.dropFirst()
        #expect(STTHintBuilder.build(terms: starred).terms == ["TELOWAY", "Groq"])
    }

    @Test func leadInIsOptionalAndCountsAgainstTheBudget() {
        let terms = [HintTerm("Claude Code", useCount: 2), HintTerm("Битрикс", useCount: 1)]
        #expect(STTHintBuilder.build(terms: terms, leadIn: "Work dictation:").prompt == "Work dictation: Claude Code, Битрикс.")
        #expect(STTHintBuilder.build(terms: terms).prompt == "Claude Code, Битрикс")
        let tight = STTHintBuilder.build(terms: terms, leadIn: "Work dictation:", maxTokens: 12)
        #expect(tight.terms == ["Claude Code"])
    }
}
