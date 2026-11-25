import Foundation
import Testing
@testable import SusuCore

/// Canned HTTP responses; no network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Data) throws -> (Int, Data))?
    nonisolated(unsafe) static var lastBody = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = Data()
        if let s = request.httpBodyStream {
            s.open(); defer { s.close() }
            var buf = [UInt8](repeating: 0, count: 65536)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
        } else { body = request.httpBody ?? Data() }
        Self.lastBody = body; Self.lastRequest = request
        do {
            let (code, data) = try Self.handler!(request, body)
            let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/2", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

func stubbedProvider(key: String? = "gsk_test") -> OpenAICompatibleTranscription {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [StubProtocol.self]
    return OpenAICompatibleTranscription(keyProvider: { key }, session: URLSession(configuration: c))
}

@Suite(.serialized) struct TranscriptionHTTPTests {
    @Test func multipartBodyHasAllFieldsAndOmitsLanguageForAuto() throws {
        var f = MultipartForm(boundary: "B")
        f.addFile("file", filename: "audio.wav", mimeType: "audio/wav", data: Data([1, 2, 3]))
        f.addField("model", "m")
        let body = f.finalized()
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n"))
        #expect(text.contains("name=\"model\"\r\n\r\nm\r\n"))
        #expect(text.hasSuffix("--B--\r\n"))
        #expect(f.contentType == "multipart/form-data; boundary=B")
    }

    @Test func requestCarriesAuthUserAgentAndFields() async throws {
        StubProtocol.handler = { _, _ in (200, Data(#"{"text":" Привет мир."}"#.utf8)) }
        let p = stubbedProvider()
        let session = try await p.begin(STTOptions(language: .auto, hint: STTHint(terms: ["Groq"], prompt: "Groq, Whisper")))
        session.append(AudioChunk(samples: [Int16](repeating: 100, count: 640), startMs: 0))
        let t = try await session.finish()
        #expect(t.text == "Привет мир.")
        #expect(t.provider == .groq && t.model == "whisper-large-v3-turbo")
        let req = try #require(StubProtocol.lastRequest)
        #expect(req.url?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer gsk_test")
        #expect(req.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Susu/") == true)
        let body = String(decoding: StubProtocol.lastBody, as: UTF8.self)
        #expect(body.contains("name=\"prompt\"\r\n\r\nGroq, Whisper"))
        #expect(body.contains("name=\"temperature\"\r\n\r\n0"))
        #expect(body.contains("name=\"response_format\"\r\n\r\njson"))
        #expect(body.contains("name=\"model\"\r\n\r\nwhisper-large-v3-turbo"))
        #expect(!body.contains("name=\"language\""))
    }

    @Test func fixedLanguageIsSent() async throws {
        StubProtocol.handler = { _, _ in (200, Data(#"{"text":"x"}"#.utf8)) }
        let s = try await stubbedProvider().begin(STTOptions(language: .fixed("ru")))
        s.append(AudioChunk(samples: [1, 2, 3], startMs: 0))
        _ = try await s.finish()
        #expect(String(decoding: StubProtocol.lastBody, as: UTF8.self).contains("name=\"language\"\r\n\r\nru"))
    }

    @Test(arguments: [(401, STTError.unauthorized), (403, .unauthorized), (402, .outOfCredit), (429, .rateLimited),
                      (500, .http(500, "boom"))])
    func httpStatusesMapToSTTError(code: Int, expected: STTError) async throws {
        StubProtocol.handler = { _, _ in (code, Data(#"{"error":{"message":"boom"}}"#.utf8)) }
        let s = try await stubbedProvider().begin(STTOptions())
        s.append(AudioChunk(samples: [1, 2, 3], startMs: 0))
        await #expect(throws: expected) { _ = try await s.finish() }
    }

    @Test func badJSONIsBadResponse() async throws {
        StubProtocol.handler = { _, _ in (200, Data("nope".utf8)) }
        let s = try await stubbedProvider().begin(STTOptions())
        s.append(AudioChunk(samples: [1], startMs: 0))
        await #expect(throws: STTError.badResponse("no `text` in response")) { _ = try await s.finish() }
    }

    @Test(arguments: [(URLError.timedOut, STTError.timeout), (URLError.notConnectedToInternet, .noNetwork),
                      (URLError.networkConnectionLost, .noNetwork), (URLError.cannotFindHost, .noNetwork),
                      (URLError.cancelled, .cancelled)])
    func transportErrorsMap(code: URLError.Code, expected: STTError) {
        #expect(OpenAICompatibleTranscription.map(transportError: URLError(code)) == expected)
    }

    @Test func missingKeyIsUnauthorizedWithoutNetwork() async {
        StubProtocol.handler = { _, _ in Issue.record("must not hit the network"); return (200, Data()) }
        await #expect(throws: STTError.unauthorized) { _ = try await stubbedProvider(key: nil).begin(STTOptions()) }
    }

    @Test func verboseJSONGivesSegments() throws {
        let body = Data(#"{"text":"a b","language":"ru","duration":3.0,"segments":[{"start":0.0,"end":1.5,"text":" a"},{"start":1.5,"end":3.0,"text":" b"}]}"#.utf8)
        let r = try OpenAICompatibleTranscription.parse(status: 200, body: body)
        #expect(r.segments == [TimedSegment(startMs: 0, endMs: 1500, text: "a"), TimedSegment(startMs: 1500, endMs: 3000, text: "b")])
        #expect(r.language == "ru")
    }

    @Test func wavRoundTrip() throws {
        let samples: [Int16] = [0, 1, -1, 32767, -32768, 1234]
        let d = try #require(WAV.decode(WAV.encode(samples)))
        #expect(d.samples == samples && d.sampleRate == 16_000 && d.channels == 1)
    }
}
