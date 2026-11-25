import Foundation
import Testing
@testable import SusuCore

/// ChatLLM stand-in: returns a fixed text, or throws.
struct StubTitleChat: ChatLLM {
    var reply: String = ""
    var fail = false
    var beforeReply: (@Sendable () async -> Void)?
    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        await beforeReply?()
        if fail { throw ChatError.noNetwork }
        return ChatResponse(text: reply, model: request.model)
    }
}

@Suite struct NoteTitlerTests {
    @Test func parsesTitleAndTags() {
        let r = NoteTitler.parse(##"{"title":"Цена до конца ноября","tags":["Поставки","#цена"]}"##)
        #expect(r == NoteTitle(title: "Цена до конца ноября", tags: ["поставки", "цена"]))
    }

    @Test func parsesInsideCodeFence() {
        let raw = "```json\n{\"title\": \"Идея для упаковки\", \"tags\": [\"упаковка\"]}\n```"
        #expect(NoteTitler.parse(raw)?.title == "Идея для упаковки")
    }

    @Test func clipsTitleToSixWordsAndTagsToThree() {
        let r = NoteTitler.parse(#"{"title":"Один два три четыре пять шесть семь восемь.","tags":["a","b","c","d","a"]}"#)
        #expect(r?.title == "Один два три четыре пять шесть")
        #expect(r?.tags == ["a", "b", "c"])
    }

    @Test func dropsQuotesAndFinalPunctuation() {
        #expect(NoteTitler.parse(#"{"title":"«Бриф на съёмку».","tags":[]}"#)?.title == "Бриф на съёмку")
    }

    @Test func malformedAnswersGiveNil() {
        #expect(NoteTitler.parse("") == nil)
        #expect(NoteTitler.parse("Вот заголовок: Привет") == nil)
        #expect(NoteTitler.parse("{not json}") == nil)
        #expect(NoteTitler.parse(#"{"tags":["a"]}"#) == nil)
        #expect(NoteTitler.parse(#"{"title":"   ","tags":[]}"#) == nil)
        #expect(NoteTitler.parse(#"{"title":"Ок","tags":"не список"}"#) == NoteTitle(title: "Ок", tags: []))
    }

    @Test func fallbackIsFirstWords() {
        #expect(NoteTitler.fallbackTitle("Надо не забыть спросить у Игоря про образцы тканей и сроки") == "Надо не забыть спросить у Игоря")
        #expect(NoteTitler.fallbackTitle("  Короткая   заметка!  ") == "Короткая заметка")
        #expect(NoteTitler.fallbackTitle("") == "")
    }

    @Test func titleUsesModelAnswer() async {
        let t = NoteTitler(llm: StubTitleChat(reply: #"{"title":"Образцы тканей","tags":["ткани"]}"#), model: "m")
        #expect(await t.title(for: "Спросить про образцы тканей") == NoteTitle(title: "Образцы тканей", tags: ["ткани"]))
    }

    @Test func titleFallsBackWithoutModelOnErrorAndOnGarbage() async {
        let text = "Спросить Игоря про сроки пошива образца и доставку"
        let expected = NoteTitle(title: "Спросить Игоря про сроки пошива образца")
        #expect(await NoteTitler(llm: nil, model: "m").title(for: text) == expected)
        #expect(await NoteTitler(llm: StubTitleChat(fail: true), model: "m").title(for: text) == expected)
        #expect(await NoteTitler(llm: StubTitleChat(reply: "извини, не могу"), model: "m").title(for: text) == expected)
    }

    @Test func requestAsksForJSONSchemaWithShortTimeout() async {
        final class Box: @unchecked Sendable { var req: ChatRequest? }
        struct Spy: ChatLLM {
            let box: Box
            func complete(_ request: ChatRequest) async throws -> ChatResponse {
                box.req = request
                return ChatResponse(text: #"{"title":"x","tags":[]}"#, model: "m")
            }
        }
        let box = Box()
        _ = await NoteTitler(llm: Spy(box: box), model: "gpt").title(for: "текст")
        #expect(box.req?.jsonSchema?.name == "note_title")
        #expect(box.req?.model == "gpt" && box.req?.task == "editor" && (box.req?.timeout ?? 99) <= 10)
    }
}
