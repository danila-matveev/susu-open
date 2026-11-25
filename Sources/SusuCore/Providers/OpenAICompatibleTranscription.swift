import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `POST {baseURL}/audio/transcriptions` client (Groq Whisper, OpenAI, any compatible server).
/// Spec 3.3 / 4.2. Dictation goes through `begin` (sessions), files through `FileTranscriber`.
public struct OpenAICompatibleTranscription: SpeechToText, FileTranscriber {
    public let id: ProviderID
    public let baseURL: URL
    public let model: String
    /// Request timeout, seconds.
    public let timeout: TimeInterval
    /// Pieces longer than this are sent during speech at the next pause (spec 3.3).
    public let splitAfterSeconds: Double
    private let keyProvider: @Sendable () -> String?
    private let session: URLSession
    private let clock: any SusuClock
    private let userAgent: String

    public init(id: ProviderID = .groq,
                baseURL: URL = URL(string: "https://api.groq.com/openai/v1")!,
                model: String = "whisper-large-v3-turbo",
                keyProvider: @escaping @Sendable () -> String?,
                session: URLSession = OpenAICompatibleTranscription.makeSession(),
                clock: any SusuClock = SystemClock(),
                timeout: TimeInterval = 15,
                splitAfterSeconds: Double = 20,
                userAgent: String = "Susu/\(Susu.version)") {
        self.id = id; self.baseURL = baseURL; self.model = model; self.keyProvider = keyProvider
        self.session = session; self.clock = clock; self.timeout = timeout
        self.splitAfterSeconds = splitAfterSeconds; self.userAgent = userAgent
    }

    public static func groq(keyProvider: @escaping @Sendable () -> String?) -> OpenAICompatibleTranscription {
        OpenAICompatibleTranscription(keyProvider: keyProvider)
    }

    /// One shared session so `prewarm` and later requests reuse the same HTTP/2 connection.
    public static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.default
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c)
    }

    // MARK: SpeechToText

    public func prewarm() async {
        var req = URLRequest(url: baseURL.appendingPathComponent("models"))
        req.timeoutInterval = 5
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let key = keyProvider() { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        _ = try? await session.data(for: req)   // result is irrelevant: the point is the open connection
    }

    public func begin(_ options: STTOptions) async throws -> any STTSession {
        try begin(options, pauseEnded: options.pauseEnded)
    }

    /// `pauseEnded(chunk)` returns true when a pause ≥ 300 ms has just ended (the dictation controller
    /// wires in the audio module's PauseDetector). Without it nothing is sent before `finish()`.
    public func begin(_ options: STTOptions, pauseEnded: (@Sendable (AudioChunk) -> Bool)?) throws -> any STTSession {
        guard keyProvider() != nil else { throw STTError.unauthorized }
        let me = self
        return ChunkedSTTSession(
            provider: id, model: model, clock: clock, splitAfterSeconds: splitAfterSeconds,
            pauseEnded: pauseEnded,
            upload: { samples, previousText in
                let prompt = Self.prompt(options.hint.prompt, previousText: previousText)
                let r = try await me.send(file: WAV.encode(samples), filename: "audio.wav", mimeType: "audio/wav",
                                          language: options.language, prompt: prompt, verbose: false)
                return UploadedText(text: r.text, language: r.language)
            })
    }

    // MARK: FileTranscriber

    public func transcribe(_ file: URL, options: FileSTTOptions) async throws -> [TimedSegment] {
        let data = try Data(contentsOf: file)
        let mime = Self.mimeType(forExtension: file.pathExtension)
        let r = try await send(file: data, filename: file.lastPathComponent, mimeType: mime,
                               language: options.language, prompt: options.hint.prompt, verbose: true)
        if !r.segments.isEmpty { return r.segments }
        let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [TimedSegment(startMs: 0, endMs: Int((r.duration ?? 0) * 1000), text: text)]
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "wav": return "audio/wav"
        case "m4a", "mp4": return "audio/mp4"
        case "mp3", "mpeg": return "audio/mpeg"
        case "ogg": return "audio/ogg"
        case "flac": return "audio/flac"
        case "webm": return "audio/webm"
        default: return "application/octet-stream"
        }
    }

    // MARK: HTTP

    struct Response {
        var text: String
        var language: String?
        var duration: Double?
        var segments: [TimedSegment]
    }

    func makeRequest(file: Data, filename: String, mimeType: String, language: LanguageMode,
                     prompt: String, verbose: Bool) throws -> (URLRequest, Data) {
        guard let key = keyProvider() else { throw STTError.unauthorized }
        var form = MultipartForm()
        form.addFile("file", filename: filename, mimeType: mimeType, data: file)
        form.addField("model", model)
        form.addField("temperature", "0")
        form.addField("response_format", verbose ? "verbose_json" : "json")
        if let code = language.isoCode { form.addField("language", code) }   // auto = field omitted
        if !prompt.isEmpty { form.addField("prompt", prompt) }
        var req = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")   // Cloudflare in front of Groq 403s without it
        return (req, form.finalized())
    }

    func send(file: Data, filename: String, mimeType: String, language: LanguageMode,
              prompt: String, verbose: Bool) async throws -> Response {
        let (req, body) = try makeRequest(file: file, filename: filename, mimeType: mimeType,
                                          language: language, prompt: prompt, verbose: verbose)
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.upload(for: req, from: body)
        } catch {
            throw Self.map(transportError: error)
        }
        guard let http = resp as? HTTPURLResponse else { throw STTError.badResponse("not an HTTP response") }
        return try Self.parse(status: http.statusCode, body: data)
    }

    // MARK: Mapping (pure, tested)

    static func map(transportError error: Error) -> STTError {
        if let e = error as? STTError { return e }
        if error is CancellationError { return .cancelled }
        guard let u = error as? URLError else { return .badResponse(error.localizedDescription) }
        switch u.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timeout
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed:
            return .noNetwork
        default: return .badResponse(u.localizedDescription)
        }
    }

    static func parse(status: Int, body: Data) throws -> Response {
        switch status {
        case 200..<300: break
        case 401, 403: throw STTError.unauthorized
        case 402: throw STTError.outOfCredit
        case 429: throw STTError.rateLimited
        default: throw STTError.http(status, errorMessage(body))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = obj["text"] as? String else {
            throw STTError.badResponse("no `text` in response")
        }
        var segments: [TimedSegment] = []
        for s in (obj["segments"] as? [[String: Any]]) ?? [] {
            guard let t = s["text"] as? String,
                  let a = (s["start"] as? NSNumber)?.doubleValue,
                  let b = (s["end"] as? NSNumber)?.doubleValue else { continue }
            let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { segments.append(TimedSegment(startMs: Int(a * 1000), endMs: Int(b * 1000), text: clean)) }
        }
        return Response(text: text, language: obj["language"] as? String,
                        duration: (obj["duration"] as? NSNumber)?.doubleValue, segments: segments)
    }

    private static func errorMessage(_ body: Data) -> String {
        if let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let e = o["error"] as? [String: Any], let m = e["message"] as? String { return m }
        return String(decoding: body.prefix(300), as: UTF8.self)
    }
}

extension OpenAICompatibleTranscription {
    /// Hint plus the end of the previous piece (Whisper continues it like a transcript), within 224 tokens.
    /// Hint terms are dropped from the end first; the context tail is kept short (~120 chars).
    static func prompt(_ hint: String, previousText: String?, maxTokens: Int = 224) -> String {
        guard let prev = previousText?.trimmingCharacters(in: .whitespacesAndNewlines), !prev.isEmpty else { return hint }
        let tail = String(prev.suffix(120))
        var terms = hint
        while !terms.isEmpty, STTHintBuilder.estimatedTokens(terms + " " + tail) > maxTokens {
            if let cut = terms.range(of: ",", options: .backwards) { terms = String(terms[..<cut.lowerBound]) } else { terms = "" }
        }
        return terms.isEmpty ? tail : terms + ". " + tail
    }
}
