import Foundation
import Testing
@testable import SusuCore

/// Fake model: answers with `reply(request)`, after `delay`. Records every request.
final class EditorFakeChat: ChatLLM, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [ChatRequest] = []
    let delay: TimeInterval
    let reply: @Sendable (ChatRequest) throws -> String

    init(delay: TimeInterval = 0, reply: @escaping @Sendable (ChatRequest) throws -> String) {
        self.delay = delay; self.reply = reply
    }

    private func record(_ r: ChatRequest) { lock.lock(); seen.append(r); lock.unlock() }

    var requests: [ChatRequest] { lock.lock(); defer { lock.unlock() }; return seen }

    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        record(request)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return ChatResponse(text: try reply(request), usage: Usage(promptTokens: 100, completionTokens: 20, costUSD: 0.0001), model: request.model)
    }
}

private let terms = ["Claude Code", "Telega.in", "SpeechKit", "Wispr Flow", "TELOWAY"]

@Suite("Editor")
struct EditorTests {
    @Test("prompt carries level instructions, dictionary, examples and context")
    func prompt() async {
        let chat = EditorFakeChat { $0.messages[1].content }
        let ctx = EditorContext(app: "Telegram", textBeforeCursor: "Привет, как дела", styleRule: "Короткие живые сообщения")
        let examples = (1...12).map { (before: "было\($0)", after: "стало\($0)") }
        let r = await Editor.edit(text: "привет клод код", level: .normal, context: ctx, terms: terms, examples: examples,
                                  chat: chat, model: "m")
        let system = chat.requests[0].messages[0].content
        #expect(chat.requests[0].messages[0].role == .system)
        #expect(chat.requests[0].messages[1].content == "привет клод код")
        #expect(system.contains("punctuation, capital letters and paragraph breaks"))
        #expect(system.contains("Claude Code\nTelega.in"))
        #expect(system.contains("было1 -> стало1"))
        #expect(system.contains("было10 -> стало10"))
        #expect(!system.contains("было11"))          // at most 10 examples
        #expect(system.contains("Короткие живые сообщения"))
        #expect(system.contains("App: Telegram"))
        #expect(system.contains("Привет, как дела"))
        #expect(chat.requests[0].task == "editor")
        #expect(r.model == "m")
    }

    @Test("names level asks for dictionary fixes only and skips context")
    func namesPrompt() async {
        let chat = EditorFakeChat { $0.messages[1].content }
        _ = await Editor.edit(text: "настрой клод код", level: .names, context: EditorContext(app: "Xcode", styleRule: "rule"),
                              terms: terms, chat: chat, model: "m")
        let system = chat.requests[0].messages[0].content
        #expect(system.contains("fix names only"))
        #expect(system.contains("Change nothing else"))
        #expect(!system.contains("Xcode"))
        #expect(!system.contains("STYLE RULE"))
    }

    @Test("careful level adds full sentences")
    func carefulPrompt() async {
        let chat = EditorFakeChat { $0.messages[1].content }
        _ = await Editor.edit(text: "привет", level: .careful, terms: terms, chat: chat, model: "m")
        #expect(chat.requests[0].messages[0].content.contains("complete well-formed sentences"))
    }

    @Test("verbatim never calls the model")
    func verbatim() async {
        let chat = EditorFakeChat { _ in "x" }
        let r = await Editor.edit(text: "как сказано", level: .verbatim, terms: terms, chat: chat, model: "m")
        #expect(chat.requests.isEmpty)
        #expect(r.text == "как сказано")
        #expect(!r.usedModel)
        #expect(r.outcome == .skipped)
    }

    @Test("names level without a dictionary has nothing to fix: no call")
    func emptyDictionary() async {
        let chat = EditorFakeChat { _ in "x" }
        let r = await Editor.edit(text: "как сказано", level: .names, chat: chat, model: "m")
        #expect(chat.requests.isEmpty)
        #expect(r.text == "как сказано")
    }

    @Test("a name is fixed by the model and the result reports model and cost")
    func fixesName() async {
        let chat = EditorFakeChat { _ in "Настрой Claude Code." }
        let r = await Editor.edit(text: "Настрой клод код", level: .names, terms: terms, chat: chat, model: "fast")
        #expect(r.usedModel)
        #expect(r.text == "Настрой Claude Code")   // names level: only the replacement lands on the step-1 text
        #expect(r.model == "fast")
        #expect(r.costUSD == 0.0001)
        #expect(r.outcome == .used)
    }

    @Test("timeout returns the rules text")
    func timeout() async {
        let chat = EditorFakeChat(delay: 30) { _ in "Настрой Claude Code" }
        let r = await Editor.edit(text: "Настрой клод код", level: .names, terms: terms, chat: chat, model: "m", timeout: 0.05)
        #expect(r.text == "Настрой клод код")
        #expect(!r.usedModel)
        #expect(r.outcome == .timedOut)
        #expect(r.latencyMs < 10_000)   // loose for slow CI; the 30 s fake proves the timeout fired
    }

    @Test("default deadlines follow the spec")
    func deadlines() {
        #expect(Editor.defaultTimeout(for: .names) == 0.35)
        #expect(Editor.defaultTimeout(for: .normal) == 1.5)
        #expect(Editor.defaultTimeout(for: .careful) == 1.5)
    }

    @Test("a failing call returns the rules text")
    func failure() async {
        let chat = EditorFakeChat { _ in throw ChatError.rateLimited }
        let r = await Editor.edit(text: "Привет мир", level: .normal, terms: terms, chat: chat, model: "m")
        #expect(r.text == "Привет мир")
        #expect(!r.usedModel)
        if case .failed = r.outcome {} else { Issue.record("expected .failed, got \(r.outcome)") }
    }

    // MARK: post-check

    @Test("names level rejects rephrasing (Д14)")
    func rejectsRephrasing() async {
        let chat = EditorFakeChat { _ in "Пожалуйста, настрой Claude Code" }
        let r = await Editor.edit(text: "Настрой клод код", level: .names, terms: terms, chat: chat, model: "m")
        #expect(r.text == "Настрой клод код")
        #expect(!r.usedModel)
        if case .rejected(.changedWords) = r.outcome {} else { Issue.record("got \(r.outcome)") }
        #expect(r.modelText == "Пожалуйста, настрой Claude Code")
    }

    @Test("names level rejects a translated word")
    func rejectsTranslation() async {
        let chat = EditorFakeChat { _ in "Настрой emulators" }
        let r = await Editor.edit(text: "Настрой эмуляторы", level: .names, terms: terms, chat: chat, model: "m")
        #expect(!r.usedModel)
        #expect(r.text == "Настрой эмуляторы")
    }

    @Test("rejects invented Latin words (Р5)")
    func rejectsInventedLatin() async {
        let chat = EditorFakeChat { _ in "Открой skills и Claude Code" }
        let r = await Editor.edit(text: "Открой скилы и клод код", level: .normal, terms: terms, chat: chat, model: "m")
        #expect(!r.usedModel)
        #expect(r.outcome == .rejected(.inventedLatin(["skills"])))
        #expect(r.text == "Открой скилы и клод код")
    }

    @Test("Latin words already in the input are fine")
    func keepsInputLatin() async {
        let chat = EditorFakeChat { _ in "Открой deep research, пожалуйста." }
        let r = await Editor.edit(text: "Открой deep research пожалуйста", level: .normal, terms: terms, chat: chat, model: "m")
        #expect(r.usedModel)
        #expect(r.text == "Открой deep research, пожалуйста.")
    }

    @Test("rejects a dictionary term that was not spoken (Р4)")
    func rejectsUnspokenTerm() async {
        let chat = EditorFakeChat { _ in "Привет, это SpeechKit." }
        let r = await Editor.edit(text: "Привет это всё", level: .normal, terms: terms, chat: chat, model: "m")
        #expect(!r.usedModel)
        if case .rejected(.unspokenTerm) = r.outcome {} else { Issue.record("got \(r.outcome)") }
    }

    @Test("rejects an answer more than 30% longer")
    func rejectsLong() async {
        let long = EditorFakeChat { _ in String(repeating: "слово ", count: 40) }
        let r2 = await Editor.edit(text: "Привет мир как дела расскажи мне подробнее", level: .careful, terms: terms, chat: long, model: "m")
        #expect(r2.outcome == .rejected(.tooLong))
    }

    @Test("normal level punctuation is accepted, a new word is not")
    func normalLevel() async {
        let ok = EditorFakeChat { _ in "Привет, мир! Как дела?" }
        let r = await Editor.edit(text: "Привет мир как дела", level: .normal, terms: terms, chat: ok, model: "m")
        #expect(r.usedModel)
        #expect(r.text == "Привет, мир! Как дела?")
        let bad = EditorFakeChat { _ in "Здравствуй, мир! Как твои дела?" }
        let r2 = await Editor.edit(text: "Привет мир как дела", level: .normal, terms: terms, chat: bad, model: "m")
        #expect(!r2.usedModel)
    }

    @Test("names level keeps punctuation and casing of the rules text, only swaps the term")
    func namesKeepsText() async {
        let chat = EditorFakeChat { _ in "Я использую Wispr Flow, в Telegram и Claude Code!" }
        let r = await Editor.edit(text: "Я использую виспер флоу, в Telegram и claude code", level: .names,
                                  terms: terms + ["Telegram"], chat: chat, model: "m")
        #expect(r.usedModel)
        #expect(r.text == "Я использую Wispr Flow, в Telegram и Claude Code")
    }

    @Test("model wrapping is stripped")
    func stripsWrapping() async {
        let chat = EditorFakeChat { _ in "```\nНастрой Claude Code\n```" }
        let r = await Editor.edit(text: "Настрой клод код", level: .names, terms: terms, chat: chat, model: "m")
        #expect(r.usedModel)
        #expect(r.text == "Настрой Claude Code")
    }
}

@Suite("EditorCheck")
struct EditorCheckTests {
    @Test("a hunk may be one word of a multi-word term")
    func partialTerm() {
        let v = EditorCheck.verdict(input: "Я использую Wiscro Flow в Cloud Code", output: "Я использую Wispr Flow в Claude Code",
                                    level: .names, terms: ["Wispr Flow", "Claude Code"])
        #expect(v == .accept("Я использую Wispr Flow в Claude Code"))
    }

    @Test("a term that sounds nothing like the spoken word is rejected")
    func soundCheck() {
        let v = EditorCheck.verdict(input: "Открой браузер", output: "Открой SpeechKit", level: .names, terms: ["SpeechKit"])
        if case .reject(.unspokenTerm) = v {} else { Issue.record("got \(v)") }
    }

    @Test("sounds-like works across scripts")
    func skeleton() {
        #expect(EditorCheck.soundsLike("клод код", "claudecode"))
        #expect(EditorCheck.soundsLike("телеграме", "telegram"))
        #expect(!EditorCheck.soundsLike("браузер", "speechkit"))
    }
}

@Suite("EditorCheck names level")
struct EditorCheckNamesTests {
    @Test("Cyrillic dictionary words are not applied at the names level")
    func cyrillicIgnored() {
        let v = EditorCheck.verdict(input: "Опыт работы с Китаем", output: "Опыт работы с Китай", level: .names, terms: ["Китай"])
        #expect(v == .accept("Опыт работы с Китаем"))
    }

    @Test("a half-matching term (Клода -> Claude Code) is rejected")
    func halfMatch() {
        let v = EditorCheck.verdict(input: "Через Клода", output: "Через Claude Code", level: .names, terms: ["Claude Code"])
        if case .reject = v {} else { Issue.record("got \(v)") }
    }
}
