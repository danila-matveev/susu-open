import Foundation
import Testing
@testable import SusuCore

@Suite struct ChatClientTests {
    let req = ChatRequest(model: "llama-3.1-8b-instant", messages: [.system("be brief"), .user("hi")])

    @Test func parsesGroqResponse() async throws {
        let (chat, base) = makeChat(.http(200, Fixtures.groq))
        let r = try await chat.complete(req)
        #expect(r.text == "Привет, мир.")
        #expect(r.usage == Usage(promptTokens: 120, completionTokens: 8, costUSD: nil))
        #expect(r.model == "llama-3.1-8b-instant")
        let sent = try #require(StubURLProtocol.requests(for: base).first)
        #expect(sent.request.url?.path == "/v1/chat/completions")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(sent.request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Susu/") == true)
    }

    @Test func openRouterCostAndZeroRetentionFields() async throws {
        let (chat, base) = makeChat(.http(200, Fixtures.openRouter), profile: .openRouter(referer: "https://susu.app"))
        let r = try await chat.complete(req)
        #expect(r.usage.costUSD == 0.0000105)
        let sent = try #require(StubURLProtocol.requests(for: base).first)
        #expect(sent.request.value(forHTTPHeaderField: "HTTP-Referer") == "https://susu.app")
        #expect(sent.request.value(forHTTPHeaderField: "X-Title") == "Susu")
        let body = jsonObject(sent.body)
        #expect((body["provider"] as? [String: Any])?["data_collection"] as? String == "deny")
        #expect((body["usage"] as? [String: Any])?["include"] as? Bool == true)
    }

    @Test func parsesToolCalls() async throws {
        let (chat, _) = makeChat(.http(200, Fixtures.toolCalls))
        let r = try await chat.complete(req)
        #expect(r.text == "")
        #expect(r.toolCalls == [ToolCall(id: "call_1", name: "add_task", argumentsJSON: "{\"title\":\"Buy milk\"}"),
                                ToolCall(id: "call_2", name: "open_app", argumentsJSON: "{\"name\":\"Notes\"}")])
    }

    @Test func requestBodyShape() async throws {
        let (chat, base) = makeChat(.http(200, Fixtures.groq))
        var r = req
        r.messages += [
            ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c1", name: "f", argumentsJSON: "{\"a\":1}")]),
            ChatMessage(role: .tool, content: "done", toolCallID: "c1"),
        ]
        r.tools = [ToolSpec(name: "f", description: "does f", parametersJSON: #"{"type":"object","properties":{"a":{"type":"integer"}}}"#)]
        r.jsonSchema = (name: "out", schemaJSON: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#)
        r.temperature = 0.2; r.maxTokens = 64
        _ = try await chat.complete(r)
        let body = jsonObject(try #require(StubURLProtocol.requests(for: base).first).body)
        #expect(body["model"] as? String == "llama-3.1-8b-instant")
        #expect(body["temperature"] as? Double == 0.2)
        #expect(body["max_tokens"] as? Int == 64)
        #expect(body["stream"] == nil)
        let rf = try #require(body["response_format"] as? [String: Any])
        #expect(rf["type"] as? String == "json_schema")
        let js = try #require(rf["json_schema"] as? [String: Any])
        #expect(js["name"] as? String == "out")
        #expect(js["strict"] as? Bool == true)
        #expect((js["schema"] as? [String: Any])?["type"] as? String == "object")
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools[0]["type"] as? String == "function")
        let fn = try #require(tools[0]["function"] as? [String: Any])
        #expect(fn["name"] as? String == "f")
        #expect((fn["parameters"] as? [String: Any])?["type"] as? String == "object")
        let msgs = try #require(body["messages"] as? [[String: Any]])
        #expect(msgs.count == 4)
        #expect(msgs[2]["content"] is NSNull)
        let calls = try #require(msgs[2]["tool_calls"] as? [[String: Any]])
        #expect((calls[0]["function"] as? [String: Any])?["arguments"] as? String == "{\"a\":1}")
        #expect(msgs[3]["role"] as? String == "tool")
        #expect(msgs[3]["tool_call_id"] as? String == "c1")
    }

    @Test func noKeyMeansNoAuthHeader() async throws {
        let (chat, base) = makeChat(.http(200, Fixtures.groq), key: nil)
        _ = try await chat.complete(req)
        #expect(StubURLProtocol.requests(for: base).first?.request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test(arguments: [
        (401, ChatError.unauthorized), (403, .unauthorized), (402, .outOfCredit), (429, .rateLimited),
    ])
    func mapsHTTPErrors(status: Int, expected: ChatError) async {
        let (chat, _) = makeChat(.http(status, #"{"error":{"message":"nope"}}"#))
        await #expect(throws: expected) { try await chat.complete(req) }
    }

    @Test func otherHTTPErrorKeepsStatusAndBody() async {
        let (chat, _) = makeChat(.http(503, "overloaded"))
        await #expect(throws: ChatError.http(503, "overloaded")) { try await chat.complete(req) }
    }

    @Test func mapsTransportErrors() async {
        let (slow, _) = makeChat(.fail(.timedOut))
        await #expect(throws: ChatError.timeout) { try await slow.complete(req) }
        let (offline, _) = makeChat(.fail(.notConnectedToInternet))
        await #expect(throws: ChatError.noNetwork) { try await offline.complete(req) }
    }

    @Test func garbageIsBadResponse() async {
        let (chat, _) = makeChat(.http(200, "<html>"))
        await #expect(throws: ChatError.badResponse("not a JSON object")) { try await chat.complete(req) }
    }

    @Test func streamAssemblesTextToolCallsAndUsage() async throws {
        let (chat, base) = makeChat(.http(200, Fixtures.sse))
        let collected = Collector()
        let r = try await chat.completeStreaming(req) { collected.add($0) }
        #expect(r.text == "Hello")
        #expect(collected.items == ["Hel", "lo"])
        #expect(r.toolCalls == [ToolCall(id: "c1", name: "add_task", argumentsJSON: "{\"title\":\"x\"}")])
        #expect(r.usage == Usage(promptTokens: 7, completionTokens: 3, costUSD: 0.001))
        let body = jsonObject(try #require(StubURLProtocol.requests(for: base).first).body)
        #expect(body["stream"] as? Bool == true)
    }

    @Test func streamYieldsTextDeltas() async throws {
        let (chat, _) = makeChat(.http(200, Fixtures.sse))
        var pieces: [String] = []
        for try await d in chat.stream(req) { pieces.append(d) }
        #expect(pieces == ["Hel", "lo"])
    }

    @Test func streamHTTPErrorIsMapped() async {
        let (chat, _) = makeChat(.http(402, "no credit"))
        await #expect(throws: ChatError.outOfCredit) {
            for try await _ in chat.stream(req) {}
        }
    }
}
