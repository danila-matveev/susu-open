import Testing
@testable import SusuCore

struct RulesCase: Sendable, CustomTestStringConvertible {
    var input: String
    var expected: String
    var testDescription: String { "\(input) -> \(expected)" }
    init(_ input: String, _ expected: String) { self.input = input; self.expected = expected }
}

private let dict = [
    RulesEntry(id: "d1", phrase: "спич кит", replacement: "SpeechKit"),
    RulesEntry(id: "d2", phrase: "клод", replacement: "Claude"),
    RulesEntry(id: "d3", phrase: "iphone", replacement: "iPhone"),
    RulesEntry(id: "d4", phrase: "open ai", replacement: "OpenAI"),
]
private let snippets = [
    RulesEntry(id: "s1", phrase: "мой адрес", replacement: "Сан-Паулу,\n  Rua Augusta 100"),
    RulesEntry(id: "s2", phrase: "sig", replacement: "Best regards,\nDanya"),
]

@Suite("CleanupRules")
struct RulesTests {
    @Test("fillers and repeats", arguments: [
        RulesCase("э привет", "Привет"),
        RulesCase("Я, э, думаю, что да", "Я, думаю, что да"),
        RulesCase("ну ээ давай", "Ну давай"),
        RulesCase("эм, ладно", "Ладно"),
        RulesCase("ммм хорошо", "Хорошо"),
        RulesCase("э-э-э не знаю", "Не знаю"),
        RulesCase("uh, I think so", "I think so"),
        RulesCase("so um we should go", "So we should go"),
        RulesCase("erm... maybe", "Maybe"),
        RulesCase("это эмоция", "Это эмоция"),
        RulesCase("экран и эхо", "Экран и эхо"),
        RulesCase("the umbrella is here", "The umbrella is here"),
        RulesCase("длина 10 мм", "Длина 10 мм"),
        RulesCase("я я думаю", "Я думаю"),
        RulesCase("Я я думаю", "Я думаю"),
        RulesCase("I I think so", "I think so"),
        RulesCase("да да да", "Да"),
        RulesCase("в 10 10 часов", "В 10 10 часов"),
        RulesCase("да, да", "Да, да"),
        RulesCase("привет\nя я здесь", "Привет\nя здесь"),
    ])
    func fillersAndRepeats(_ c: RulesCase) {
        #expect(CleanupRules.apply(c.input).text == c.expected)
    }

    @Test("whitespace, punctuation and capitalisation", arguments: [
        RulesCase("привет  ,  мир", "Привет, мир"),
        RulesCase("  привет мир  ", "Привет мир"),
        RulesCase("что ? да !", "Что? да!"),
        RulesCase("«привет»", "«Привет»"),
        RulesCase("123 штуки", "123 штуки"),
        RulesCase("привет\n\nмир", "Привет\n\nмир"),
        RulesCase("hello   world .", "Hello world."),
    ])
    func whitespace(_ c: RulesCase) {
        #expect(CleanupRules.apply(c.input).text == c.expected)
    }

    @Test func verbatimKeepsCase() {
        let r = CleanupRules.apply("привет  мир", options: RulesOptions(capitalize: false))
        #expect(r.text == "привет мир")
    }

    @Test("dictionary replacements", arguments: [
        RulesCase("запусти спич кит", "Запусти SpeechKit"),
        RulesCase("Запусти СПИЧ  КИТ сейчас", "Запусти SpeechKit сейчас"),
        RulesCase("спроси у клода", "Спроси у клода"),
        RulesCase("клод, привет", "Claude, привет"),
        RulesCase("скажи Клод", "Скажи Claude"),
        RulesCase("iphone новый", "iPhone новый"),
        RulesCase("купи iphones", "Купи iphones"),
        RulesCase("open ai и клод", "OpenAI и Claude"),
        RulesCase("клоды все", "Клоды все"),
    ])
    func replacements(_ c: RulesCase) {
        let r = CleanupRules.apply(c.input, options: RulesOptions(replacements: dict))
        #expect(r.text == c.expected)
    }

    @Test func appliedReplacementsListsFiredEntriesOnce() {
        let r = CleanupRules.apply("клод и клод, спич кит", options: RulesOptions(replacements: dict, snippets: snippets))
        #expect(r.appliedReplacements == ["d1", "d2"] || r.appliedReplacements == ["d2", "d1"])
        #expect(r.appliedReplacements.count == 2)
        let none = CleanupRules.apply("просто текст", options: RulesOptions(replacements: dict))
        #expect(none.appliedReplacements.isEmpty)
    }

    @Test func replacementIsNotRecapitalisedOrReprocessed() {
        // "iPhone" at sentence start must not become "IPhone"
        #expect(CleanupRules.apply("iphone", options: RulesOptions(replacements: dict)).text == "iPhone")
    }

    @Test func replacementOutputIsNotCollapsedAsRepeat() {
        let e = [RulesEntry(phrase: "бу", replacement: "ха ха")]
        #expect(CleanupRules.apply("бу", options: RulesOptions(replacements: e)).text == "ха ха")
    }

    @Test func snippetsExpandVerbatim() {
        let r = CleanupRules.apply("вот мой адрес", options: RulesOptions(snippets: snippets))
        #expect(r.text == "Вот Сан-Паулу,\n  Rua Augusta 100")
        #expect(r.appliedReplacements == ["s2"] || r.appliedReplacements == ["s1"])
        let sig = CleanupRules.apply("Sig", options: RulesOptions(snippets: snippets))
        #expect(sig.text == "Best regards,\nDanya")
        #expect(CleanupRules.apply("signal", options: RulesOptions(snippets: snippets)).text == "Signal")
    }

    @Test("hallucinations at the end", arguments: [
        RulesCase("Привет, как дела. Продолжение следует...", "Привет, как дела."),
        RulesCase("Всё готово. Спасибо за просмотр!", "Всё готово."),
        RulesCase("Текст здесь. Субтитры сделал DimaTorzok", "Текст здесь."),
        RulesCase("Текст здесь. Субтитры создавал DimaTorzok", "Текст здесь."),
        RulesCase("Текст здесь. Субтитры подогнал Taaskaa", "Текст здесь."),
        RulesCase("Текст здесь. Редактор субтитров А.Семкин Корректор А.Егорова", "Текст здесь."),
        RulesCase("Подписывайтесь на канал", ""),
        RulesCase("Done. Thanks for watching!", "Done."),
        RulesCase("Done. Thank you for watching.", "Done."),
        RulesCase("Done.\nThank you for watching", "Done."),
        // not at the end / not a whole sentence: stay
        RulesCase("Продолжение следует в понедельник", "Продолжение следует в понедельник"),
        RulesCase("Продолжение следует. Потом обсудим", "Продолжение следует. Потом обсудим"),
        RulesCase("Я сказал спасибо за просмотр", "Я сказал спасибо за просмотр"),
    ])
    func hallucinations(_ c: RulesCase) {
        #expect(CleanupRules.apply(c.input).text == c.expected)
    }

    @Test("voice commands at the end", arguments: [
        RulesCase("привет, нажми Enter", "Привет"),
        RulesCase("привет нажми энтер.", "Привет"),
        RulesCase("Скажи ему привет и отправь", "Скажи ему привет"),
        RulesCase("готово, отправь", "Готово"),
        RulesCase("всё готово. Отправь.", "Всё готово."),
        RulesCase("ok good press enter", "Ok good"),
        RulesCase("ok, send it", "Ok"),
        RulesCase("Нажми Enter", ""),
    ])
    func commandsFire(_ c: RulesCase) {
        let r = CleanupRules.apply(c.input, options: RulesOptions(voiceCommandsEnabled: true))
        #expect(r.text == c.expected)
        #expect(r.pressEnter)
    }

    @Test("voice commands in the middle do nothing", arguments: [
        RulesCase("отправь ему файл и всё", "Отправь ему файл и всё"),
        RulesCase("нажми Enter и посмотри что будет", "Нажми Enter и посмотри что будет"),
        RulesCase("press enter to continue please", "Press enter to continue please"),
        RulesCase("он отправил письмо", "Он отправил письмо"),
        RulesCase("send it tomorrow", "Send it tomorrow"),
    ])
    func commandsInMiddle(_ c: RulesCase) {
        let r = CleanupRules.apply(c.input, options: RulesOptions(voiceCommandsEnabled: true))
        #expect(r.text == c.expected)
        #expect(!r.pressEnter)
    }

    @Test func commandsOffByDefault() {
        let r = CleanupRules.apply("привет, отправь")
        #expect(r.text == "Привет, отправь")
        #expect(!r.pressEnter)
    }

    @Test func hallucinationThenCommand() {
        let r = CleanupRules.apply("Привет. Отправь. Продолжение следует", options: RulesOptions(voiceCommandsEnabled: true))
        #expect(r.text == "Привет.")
        #expect(r.pressEnter)
    }

    @Test func emptyAndPerformance() {
        #expect(CleanupRules.apply("").text == "")
        let long = String(repeating: "я я думаю э что клод это спич кит. ", count: 40)
        let opts = RulesOptions(replacements: dict, snippets: snippets, voiceCommandsEnabled: true)
        let t0 = ContinuousClock.now
        _ = CleanupRules.apply(long, options: opts)
        #expect(ContinuousClock.now - t0 < .milliseconds(100))   // generous bound; real cost is a few ms
    }

    @Test func dictionaryEntryAdapter() {
        let e = DictionaryEntry(id: "x", kind: "replacement", phrase: "клод", replacement: "Claude")
        #expect(RulesEntry(e) == RulesEntry(id: "x", phrase: "клод", replacement: "Claude"))
        #expect(RulesEntry(DictionaryEntry(phrase: "word")) == nil)
    }
}
