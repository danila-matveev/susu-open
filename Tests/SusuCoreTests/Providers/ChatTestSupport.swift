import Foundation
@testable import SusuCore

/// URLProtocol stub keyed by host, so parallel tests do not see each other's handlers.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable { var request: URLRequest; var body: Data }
    enum Reply: Sendable {
        case http(Int, String)
        case fail(URLError.Code)
    }
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var captured: [String: [Captured]] = [:]
    private static let lock = NSLock()

    /// Registers a reply and returns a fresh base URL (unique host) to talk to it.
    static func register(_ reply: Reply) -> URL {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        lock.lock(); replies[host] = reply; lock.unlock()
        return URL(string: "https://\(host)/v1")!
    }
    static func requests(for base: URL) -> [Captured] {
        lock.lock(); defer { lock.unlock() }
        return captured[base.host ?? ""] ?? []
    }
    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let host = request.url?.host ?? ""
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
        }
        Self.lock.lock()
        Self.captured[host, default: []].append(Captured(request: request, body: body))
        let reply = Self.replies[host]
        Self.lock.unlock()
        switch reply {
        case .http(let status, let text)?:
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code)?:
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
        }
    }
}

func jsonObject(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

func makeChat(_ reply: StubURLProtocol.Reply, profile: OpenAICompatibleChat.Profile = .generic,
              key: String? = "sk-test") -> (OpenAICompatibleChat, URL) {
    let base = StubURLProtocol.register(reply)
    return (OpenAICompatibleChat(baseURL: base, apiKey: { key }, profile: profile, session: StubURLProtocol.session), base)
}

/// Fake provider for fallback tests.
struct FakeChat: ChatLLM {
    var result: Result<ChatResponse, ChatError>
    func complete(_ request: ChatRequest) async throws -> ChatResponse { try result.get() }
}

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [String] = []
    func add(_ s: String) { lock.lock(); _items.append(s); lock.unlock() }
    var items: [String] { lock.lock(); defer { lock.unlock() }; return _items }
}

enum Fixtures {
    static let groq = """
    {"id":"chatcmpl-1","object":"chat.completion","model":"llama-3.1-8b-instant",
     "choices":[{"index":0,"message":{"role":"assistant","content":"Привет, мир."},"finish_reason":"stop"}],
     "usage":{"prompt_tokens":120,"completion_tokens":8,"total_tokens":128,"queue_time":0.01}}
    """
    static let openRouter = """
    {"id":"gen-1","model":"openai/gpt-oss-120b","provider":"Groq",
     "choices":[{"message":{"role":"assistant","content":"Hello"}}],
     "usage":{"prompt_tokens":50,"completion_tokens":5,"total_tokens":55,"cost":0.0000105}}
    """
    static let toolCalls = """
    {"model":"m","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
      {"id":"call_1","type":"function","function":{"name":"add_task","arguments":"{\\"title\\":\\"Buy milk\\"}"}},
      {"id":"call_2","type":"function","function":{"name":"open_app","arguments":"{\\"name\\":\\"Notes\\"}"}}]}}],
     "usage":{"prompt_tokens":10,"completion_tokens":20}}
    """
    static let sse = """
    : keep-alive

    data: {"model":"m","choices":[{"delta":{"role":"assistant","content":""}}]}

    data: {"model":"m","choices":[{"delta":{"content":"Hel"}}]}

    data: {"model":"m","choices":[{"delta":{"content":"lo"}}]}

    data: {"model":"m","choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"add_task","arguments":"{\\"ti"}}]}}]}

    data: {"model":"m","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"tle\\":\\"x\\"}"}}]}}]}

    data: {"model":"m","choices":[],"usage":{"prompt_tokens":7,"completion_tokens":3,"cost":0.001}}

    data: [DONE]

    """
}
