// The one chat client of Susu (spec 4.2): POST {baseURL}/chat/completions, OpenAI wire format.
// Covers Groq, OpenRouter, OpenAI, Ollama, LM Studio and any custom address.
import Foundation

public struct OpenAICompatibleChat: ChatLLM {
    /// Per-provider additions to the request.
    public struct Profile: Sendable, Equatable {
        public var extraHeaders: [String: String]
        /// Extra top-level JSON fields (e.g. OpenRouter `provider`, `usage`).
        public var extraBody: [String: JSONValue]
        public init(extraHeaders: [String: String] = [:], extraBody: [String: JSONValue] = [:]) {
            self.extraHeaders = extraHeaders; self.extraBody = extraBody
        }
        public static let generic = Profile()
        /// Zero retention (spec 7): never let OpenRouter route to providers that log prompts; ask for cost.
        public static func openRouter(referer: String? = nil, title: String? = "Susu") -> Profile {
            var headers: [String: String] = [:]
            if let referer { headers["HTTP-Referer"] = referer }
            if let title { headers["X-Title"] = title }
            return Profile(extraHeaders: headers, extraBody: [
                "provider": .object(["data_collection": .string("deny")]),
                "usage": .object(["include": .bool(true)]),
            ])
        }
    }

    public let baseURL: URL
    public let profile: Profile
    public let userAgent: String
    let apiKey: @Sendable () -> String?
    let session: URLSession

    public init(baseURL: URL, apiKey: @escaping @Sendable () -> String?, profile: Profile = .generic,
                userAgent: String = "Susu/\(Susu.version)", session: URLSession = .shared) {
        self.baseURL = baseURL; self.apiKey = apiKey; self.profile = profile
        self.userAgent = userAgent; self.session = session
    }

    public func complete(_ request: ChatRequest) async throws -> ChatResponse {
        let urlRequest = try makeURLRequest(request, stream: false)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: urlRequest) } catch { throw ChatError.from(error) }
        guard let http = response as? HTTPURLResponse else { throw ChatError.badResponse("not an HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw ChatError.from(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return try Self.parseResponse(data, requested: request.model)
    }

    /// Streams text deltas; tool calls and usage are ignored here (use `completeStreaming` for those).
    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await completeStreaming(request) { continuation.yield($0) }
                    continuation.finish()
                } catch { continuation.finish(throwing: ChatError.from(error)) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Streaming call that returns the assembled response; `onDelta` gets each text piece as it arrives.
    public func completeStreaming(_ request: ChatRequest,
                                  onDelta: @Sendable (String) -> Void = { _ in }) async throws -> ChatResponse {
        let urlRequest = try makeURLRequest(request, stream: true)
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw ChatError.badResponse("not an HTTP response") }
            guard (200..<300).contains(http.statusCode) else {
                var body = ""
                for try await line in bytes.lines { body += line; if body.count > 300 { break } }
                throw ChatError.from(status: http.statusCode, body: body)
            }
            var assembler = SSEAssembler(requestedModel: request.model)
            for try await line in bytes.lines {
                if let delta = try assembler.feed(line: line), !delta.isEmpty { onDelta(delta) }
                if assembler.isDone { break }
            }
            return assembler.response()
        } catch { throw ChatError.from(error) }
    }

    // MARK: - Request

    func makeURLRequest(_ request: ChatRequest, stream: Bool) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = request.timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let key = apiKey(), !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        for (k, v) in profile.extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try Self.body(for: request, stream: stream, profile: profile)
        return req
    }

    static func body(for request: ChatRequest, stream: Bool, profile: Profile) throws -> Data {
        var body: [String: Any] = [
            "model": request.model,
            "messages": request.messages.map(messageJSON),
        ]
        if !request.tools.isEmpty {
            body["tools"] = try request.tools.map { tool -> [String: Any] in
                ["type": "function",
                 "function": ["name": tool.name, "description": tool.description,
                              "parameters": try parseJSON(tool.parametersJSON, what: "tool \(tool.name) parameters")]]
            }
        }
        if let schema = request.jsonSchema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": schema.name, "strict": true,
                                "schema": try parseJSON(schema.schemaJSON, what: "json schema \(schema.name)")],
            ]
        }
        if let t = request.temperature { body["temperature"] = t }
        if let m = request.maxTokens { body["max_tokens"] = m }
        if stream {
            body["stream"] = true
            body["stream_options"] = ["include_usage": true]
        }
        for (k, v) in profile.extraBody { body[k] = try parseJSON(v) }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func messageJSON(_ m: ChatMessage) -> [String: Any] {
        var out: [String: Any] = ["role": m.role.rawValue]
        if let calls = m.toolCalls, !calls.isEmpty {
            out["content"] = m.content.isEmpty ? NSNull() : m.content
            out["tool_calls"] = calls.map {
                ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.argumentsJSON]]
            }
        } else {
            out["content"] = m.content
        }
        if let id = m.toolCallID { out["tool_call_id"] = id }
        return out
    }

    private static func parseJSON(_ s: String, what: String) throws -> Any {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed]) else {
            throw ChatError.badResponse("invalid JSON in \(what)")
        }
        return obj
    }

    private static func parseJSON(_ v: JSONValue) throws -> Any {
        let data = try JSONEncoder().encode(v)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // MARK: - Response

    static func parseResponse(_ data: Data, requested: String) throws -> ChatResponse {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatError.badResponse("not a JSON object")
        }
        guard let choice = (root["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw ChatError.badResponse("no choices in response")
        }
        let text = message["content"] as? String ?? ""
        var calls: [ToolCall] = []
        for c in message["tool_calls"] as? [[String: Any]] ?? [] {
            let fn = c["function"] as? [String: Any]
            calls.append(ToolCall(id: c["id"] as? String ?? "", name: fn?["name"] as? String ?? "",
                                  argumentsJSON: fn?["arguments"] as? String ?? "{}"))
        }
        return ChatResponse(text: text, toolCalls: calls, usage: parseUsage(root["usage"]),
                            model: root["model"] as? String ?? requested)
    }

    static func parseUsage(_ any: Any?) -> Usage {
        guard let u = any as? [String: Any] else { return Usage() }
        func int(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
        return Usage(promptTokens: int("prompt_tokens"), completionTokens: int("completion_tokens"),
                     costUSD: (u["cost"] as? NSNumber)?.doubleValue)
    }
}

/// Builds one `ChatResponse` out of `data: {...}` server-sent events.
struct SSEAssembler {
    private(set) var isDone = false
    private var text = ""
    private var model: String
    private var usage = Usage()
    private var calls: [Int: (id: String, name: String, args: String)] = [:]

    init(requestedModel: String) { model = requestedModel }

    /// Returns the text delta carried by this line, if any.
    mutating func feed(line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }   // comments (": keep-alive") and other fields
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { isDone = true; return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw ChatError.badResponse("bad SSE chunk")
        }
        if let err = obj["error"] as? [String: Any] {
            throw ChatError.badResponse((err["message"] as? String) ?? "stream error")
        }
        if let m = obj["model"] as? String { model = m }
        if obj["usage"] != nil, !(obj["usage"] is NSNull) { usage = OpenAICompatibleChat.parseUsage(obj["usage"]) }
        guard let delta = ((obj["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any] else { return nil }
        for c in delta["tool_calls"] as? [[String: Any]] ?? [] {
            let idx = (c["index"] as? NSNumber)?.intValue ?? 0
            var cur = calls[idx] ?? (id: "", name: "", args: "")
            if let id = c["id"] as? String { cur.id = id }
            if let fn = c["function"] as? [String: Any] {
                if let n = fn["name"] as? String { cur.name += n }
                if let a = fn["arguments"] as? String { cur.args += a }
            }
            calls[idx] = cur
        }
        if let piece = delta["content"] as? String { text += piece; return piece }
        return nil
    }

    func response() -> ChatResponse {
        let toolCalls = calls.keys.sorted().map { i -> ToolCall in
            let c = calls[i]!
            return ToolCall(id: c.id, name: c.name, argumentsJSON: c.args.isEmpty ? "{}" : c.args)
        }
        return ChatResponse(text: text, toolCalls: toolCalls, usage: usage, model: model)
    }
}
