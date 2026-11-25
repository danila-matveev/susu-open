// Contracts between SusuCore modules (spec 2.4). Names and shapes are fixed by the spec;
// modules talk to each other only through these types. Must build for iOS too.
import Foundation

// MARK: - Common

public struct ProviderID: Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }

    public static let groq: ProviderID = "groq"
    public static let openRouter: ProviderID = "openrouter"
    public static let gigaAM: ProviderID = "gigaam-local"
}

/// Monotonic-ish time source so timeout logic is testable with fake clocks.
public protocol SusuClock: Sendable {
    /// Seconds since an arbitrary fixed point.
    func now() -> TimeInterval
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemClock: SusuClock {
    public init() {}
    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

// MARK: - Audio

/// 16 kHz mono Int16. Live chunks are 40 ms (640 samples); the last chunk may be shorter.
public struct AudioChunk: Sendable, Equatable {
    public static let sampleRate = 16_000
    public static let samplesPer40ms = 640
    public var samples: [Int16]
    /// Offset of the first sample from the start of the recording, ms.
    public var startMs: Int
    public init(samples: [Int16], startMs: Int) {
        self.samples = samples
        self.startMs = startMs
    }
    public var durationMs: Int { samples.count * 1000 / Self.sampleRate }
}

public enum LanguageMode: Codable, Sendable, Equatable, Hashable {
    case auto
    case fixed(String)   // ISO 639-1, e.g. "ru", "en"

    /// Value for the `language` field of OpenAI-compatible APIs (nil = auto).
    public var isoCode: String? {
        if case .fixed(let code) = self { return code }
        return nil
    }
}

// MARK: - Context

/// "Where the user is" at key-down (spec 3.6, T2.2). Password fields are never read.
public struct ContextSnapshot: Sendable, Equatable, Codable {
    public var appName: String?
    public var bundleID: String?
    public var pid: Int32?
    public var windowTitle: String?
    public var url: String?
    /// Stable-ish identity of the focused element (role + frame), to detect "same field".
    public var focusedElementID: String?
    public var focusedRole: String?
    /// ≤ 500 characters before the caret.
    public var textBeforeCursor: String?
    public var selectedText: String?
    public var isSecureField: Bool
    /// App is in the exclusion list: only app identity is captured.
    public var excluded: Bool

    public init(appName: String? = nil, bundleID: String? = nil, pid: Int32? = nil,
                windowTitle: String? = nil, url: String? = nil, focusedElementID: String? = nil,
                focusedRole: String? = nil, textBeforeCursor: String? = nil, selectedText: String? = nil,
                isSecureField: Bool = false, excluded: Bool = false) {
        self.appName = appName; self.bundleID = bundleID; self.pid = pid
        self.windowTitle = windowTitle; self.url = url; self.focusedElementID = focusedElementID
        self.focusedRole = focusedRole; self.textBeforeCursor = textBeforeCursor
        self.selectedText = selectedText; self.isSecureField = isSecureField; self.excluded = excluded
    }
}

// MARK: - Speech to text

public struct STTHint: Sendable, Equatable {
    public var terms: [String]
    /// Terms joined for the provider's `prompt` field, already trimmed to its limit.
    public var prompt: String
    public init(terms: [String] = [], prompt: String = "") { self.terms = terms; self.prompt = prompt }
    public static let empty = STTHint()
}

public struct STTOptions: Sendable {
    public var language: LanguageMode
    public var hint: STTHint
    public var context: ContextSnapshot?
    /// Pause signal for long speech (true = a pause ≥ 300 ms just ended at this chunk). Providers that
    /// take whole files use it to send pieces during speech (spec 3.3); others ignore it.
    public var pauseEnded: (@Sendable (AudioChunk) -> Bool)?
    public init(language: LanguageMode = .auto, hint: STTHint = .empty, context: ContextSnapshot? = nil,
                pauseEnded: (@Sendable (AudioChunk) -> Bool)? = nil) {
        self.language = language; self.hint = hint; self.context = context; self.pauseEnded = pauseEnded
    }
}

public struct Transcript: Sendable, Equatable {
    public var text: String
    public var language: String?
    public var provider: ProviderID
    public var model: String
    public var audioSeconds: Double
    public var networkMs: Int
    public init(text: String, language: String? = nil, provider: ProviderID, model: String,
                audioSeconds: Double, networkMs: Int) {
        self.text = text; self.language = language; self.provider = provider
        self.model = model; self.audioSeconds = audioSeconds; self.networkMs = networkMs
    }
}

/// Streaming-style dictation recognition: begin → append 40 ms chunks → finish.
public protocol SpeechToText: Sendable {
    var id: ProviderID { get }
    /// Open the connection ahead of time (called on key-down).
    func prewarm() async
    func begin(_ options: STTOptions) async throws -> any STTSession
}

public protocol STTSession: Sendable {
    func append(_ chunk: AudioChunk)
    func finish() async throws -> Transcript
    func cancel()
    /// Partial text if the provider supports it; finishes empty otherwise.
    var partials: AsyncStream<String> { get }
}

public struct TimedSegment: Sendable, Equatable, Codable {
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var speaker: String?
    public init(startMs: Int, endMs: Int, text: String, speaker: String? = nil) {
        self.startMs = startMs; self.endMs = endMs; self.text = text; self.speaker = speaker
    }
}

public struct FileSTTOptions: Sendable {
    public var language: LanguageMode
    public var hint: STTHint
    public init(language: LanguageMode = .auto, hint: STTHint = .empty) {
        self.language = language; self.hint = hint
    }
}

/// File recognition (calls, fallback, "redo").
public protocol FileTranscriber: Sendable {
    func transcribe(_ file: URL, options: FileSTTOptions) async throws -> [TimedSegment]
}

public enum STTError: Error, Equatable, Sendable {
    case noNetwork
    case unauthorized          // 401/403
    case outOfCredit           // 402
    case rateLimited           // 429
    case timeout
    case http(Int, String)
    case badResponse(String)
    case modelMissing(String)
    case cancelled
}

// MARK: - Chat LLM (spec 4.2: one OpenAI-compatible client)

public struct ChatMessage: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable { case system, user, assistant, tool }
    public var role: Role
    public var content: String
    public var toolCallID: String?
    public var toolCalls: [ToolCall]?
    public init(role: Role, content: String, toolCallID: String? = nil, toolCalls: [ToolCall]? = nil) {
        self.role = role; self.content = content; self.toolCallID = toolCallID; self.toolCalls = toolCalls
    }
    public static func system(_ s: String) -> ChatMessage { .init(role: .system, content: s) }
    public static func user(_ s: String) -> ChatMessage { .init(role: .user, content: s) }
}

public struct ToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    /// JSON Schema of the arguments, serialized.
    public var parametersJSON: String
    public init(name: String, description: String, parametersJSON: String) {
        self.name = name; self.description = description; self.parametersJSON = parametersJSON
    }
}

public struct ToolCall: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var argumentsJSON: String
    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id; self.name = name; self.argumentsJSON = argumentsJSON
    }
}

public struct Usage: Sendable, Equatable, Codable {
    public var promptTokens: Int
    public var completionTokens: Int
    /// Provider-reported cost if present (OpenRouter `usage.cost`), else nil.
    public var costUSD: Double?
    public init(promptTokens: Int = 0, completionTokens: Int = 0, costUSD: Double? = nil) {
        self.promptTokens = promptTokens; self.completionTokens = completionTokens; self.costUSD = costUSD
    }
}

public struct ChatRequest: Sendable {
    public var model: String
    public var messages: [ChatMessage]
    public var tools: [ToolSpec]
    /// `response_format: json_schema` when set (name, schema JSON).
    public var jsonSchema: (name: String, schemaJSON: String)?
    public var temperature: Double?
    public var maxTokens: Int?
    public var timeout: TimeInterval
    /// What the spend log should file this under (`editor`, `judge`, `summary`, `agent`).
    public var task: String
    public init(model: String, messages: [ChatMessage], tools: [ToolSpec] = [],
                jsonSchema: (name: String, schemaJSON: String)? = nil, temperature: Double? = 0,
                maxTokens: Int? = nil, timeout: TimeInterval = 10, task: String = "editor") {
        self.model = model; self.messages = messages; self.tools = tools; self.jsonSchema = jsonSchema
        self.temperature = temperature; self.maxTokens = maxTokens; self.timeout = timeout; self.task = task
    }
}

public struct ChatResponse: Sendable, Equatable {
    public var text: String
    public var toolCalls: [ToolCall]
    public var usage: Usage
    public var model: String
    public init(text: String, toolCalls: [ToolCall] = [], usage: Usage = Usage(), model: String) {
        self.text = text; self.toolCalls = toolCalls; self.usage = usage; self.model = model
    }
}

public protocol ChatLLM: Sendable {
    func complete(_ request: ChatRequest) async throws -> ChatResponse
}
