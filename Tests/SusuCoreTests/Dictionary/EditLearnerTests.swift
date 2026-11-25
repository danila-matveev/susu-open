import Foundation
import Testing
@testable import SusuCore

@Suite struct EditLearnerCandidateTests {
    struct Case: Sendable {
        let name: String
        let inserted: String
        let edited: String
        var known: Set<String> = []
        /// (before, after, isReplacement)
        let expect: [[String]]
    }

    // 20 hand-written «inserted -> corrected» pairs. expect rows: [before, after, "r" if isReplacement].
    static let cases: [Case] = [
        .init(name: "Yandex SpeechKit", inserted: "Я использую Яндекс Печкид для распознавания",
              edited: "Я использую SpeechKit для распознавания", expect: [["Яндекс Печкид", "SpeechKit", "r"]]),
        .init(name: "Claude Code", inserted: "открой клод код и запусти тесты",
              edited: "открой Claude Code и запусти тесты", expect: [["клод код", "Claude Code", "r"]]),
        .init(name: "Bitrix24", inserted: "мы делаем интеграцию с битрикс двадцать четыре",
              edited: "мы делаем интеграцию с Битрикс24", expect: [["битрикс двадцать четыре", "Битрикс24", "r"]]),
        .init(name: "TickTick", inserted: "поставь задачу в тик тик", edited: "поставь задачу в TickTick",
              expect: [["тик тик", "TickTick", "r"]]),
        .init(name: "Lumera", inserted: "запиши это для люмира сегодня", edited: "запиши это для Lumera сегодня",
              expect: [["люмира", "Lumera", "r"]]),
        .init(name: "Groq", inserted: "нужно проверить груп завтра", edited: "нужно проверить Groq завтра",
              expect: [["груп", "Groq", "r"]]),
        .init(name: "split English name", inserted: "use open router for this", edited: "use OpenRouter for this",
              expect: [["open router", "OpenRouter", "r"]]),
        .init(name: "typo fix", inserted: "превет мир как дела", edited: "привет мир как дела",
              expect: [["превет", "привет", "r"]]),
        .init(name: "two fixes", inserted: "Яндекс Печкид и клод код вместе", edited: "SpeechKit и Claude Code вместе",
              expect: [["Яндекс Печкид", "SpeechKit", "r"], ["клод код", "Claude Code", "r"]]),
        .init(name: "pure insertion", inserted: "добавь в словарь", edited: "добавь в словарь Susu",
              expect: [["", "Susu", ""]]),
        .init(name: "synonym is a candidate but not a replacement", inserted: "потом пошёл домой", edited: "потом отправился спать",
              expect: [["пошёл домой", "отправился спать", ""]]),
        // Must yield nothing:
        .init(name: "case only", inserted: "привет Вася как дела", edited: "Привет вася как дела", expect: []),
        .init(name: "punctuation only", inserted: "привет как дела что нового", edited: "Привет, как дела? Что нового?", expect: []),
        .init(name: "stop-word added", inserted: "я пошёл в магазин", edited: "я пошёл в магазин и", expect: []),
        .init(name: "stop-word swapped", inserted: "положи это на стол", edited: "положи это в стол", expect: []),
        .init(name: "deletion", inserted: "ну вот привет всем", edited: "привет всем", expect: []),
        .init(name: "yo vs ye", inserted: "всё готово", edited: "все готово", expect: []),
        .init(name: "full rewrite", inserted: "мне кажется что мы должны сделать это завтра утром",
              edited: "давайте запустим релиз после обеда в пятницу", expect: []),
        .init(name: "known word, new distortion stays", inserted: "открой клод код", edited: "открой Claude Code",
              known: ["Claude Code"], expect: [["клод код", "Claude Code", "r"]]),
        .init(name: "known trigger", inserted: "открой клод код", edited: "открой Claude Code",
              known: ["клод код"], expect: []),
    ]

    @Test(arguments: cases) func candidates(_ c: Case) {
        let got = EditLearner.candidates(inserted: c.inserted, edited: c.edited, known: c.known)
            .map { [$0.before, $0.after, $0.isReplacement ? "r" : ""] }
        #expect(got == c.expect, "\(c.name)")
    }

    @Test func caseCountIsTwenty() { #expect(Self.cases.count == 20) }

    @Test func knownWordWithNewDistortionStaysACandidate() {
        // "Claude Code" is known, but "клод кот" is a new mishearing of it -> still worth a replacement.
        let got = EditLearner.candidates(inserted: "открой клод кот", edited: "открой Claude Code", known: ["claude code"])
        #expect(got.count == 1 && got[0].isReplacement)
    }

    @Test func identicalTextsYieldNothing() {
        #expect(EditLearner.candidates(inserted: "то же самое", edited: "то же самое").isEmpty)
    }

    @Test func longSpanIsDropped() {
        // 5 words changed in a row: more than the 4-word limit.
        #expect(EditLearner.candidates(inserted: "раз два три четыре пять конец", edited: "Alpha Beta Gamma Delta Epsilon конец").isEmpty)
        #expect(EditLearner.candidates(inserted: "раз два три четыре конец", edited: "Alpha Beta Gamma Delta конец").count == 1)
    }
}
