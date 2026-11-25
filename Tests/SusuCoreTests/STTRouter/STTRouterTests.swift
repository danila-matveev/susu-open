import Foundation
import Testing
@testable import SusuCore

/// Fake provider: behaviour is chosen per test. Records what audio reached it.
final class FakeSTT: SpeechToText, @unchecked Sendable {
    enum Behavior: Sendable {
        case ok(String)
        case failBegin(STTError)
        case failFinish(STTError)
        case slow(seconds: Double, text: String)
    }
    let id: ProviderID
    let behavior: Behavior
    private let lock = NSLock()
    private var _samples: [Int16] = []
    private var _cancelled = false
    private var _finishCalls = 0
    init(id: ProviderID, _ behavior: Behavior) { self.id = id; self.behavior = behavior }

    var receivedSamples: [Int16] { lock.lock(); defer { lock.unlock() }; return _samples }
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    var finishCalls: Int { lock.lock(); defer { lock.unlock() }; return _finishCalls }
    fileprivate func add(_ s: [Int16]) { lock.lock(); _samples += s; lock.unlock() }
    fileprivate func markCancelled() { lock.lock(); _cancelled = true; lock.unlock() }
    fileprivate func markFinish() { lock.lock(); _finishCalls += 1; lock.unlock() }

    func prewarm() async {}
    func begin(_ options: STTOptions) async throws -> any STTSession {
        if case .failBegin(let e) = behavior { throw e }
        return FakeSession(owner: self)
    }
}

final class FakeSession: STTSession, @unchecked Sendable {
    let owner: FakeSTT
    init(owner: FakeSTT) { self.owner = owner }
    var partials: AsyncStream<String> { AsyncStream { $0.finish() } }
    func append(_ chunk: AudioChunk) { owner.add(chunk.samples) }
    func cancel() { owner.markCancelled() }
    func finish() async throws -> Transcript {
        owner.markFinish()
        switch owner.behavior {
        case .ok(let t):
            return Transcript(text: t, provider: owner.id, model: "fake", audioSeconds: 1, networkMs: 5)
        case .failFinish(let e):
            throw e
        case .slow(let s, let t):
            try await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
            return Transcript(text: t, provider: owner.id, model: "fake", audioSeconds: 1, networkMs: 5)
        case .failBegin:
            throw STTError.noNetwork
        }
    }
}

final class RoutedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RoutedTranscript] = []
    func add(_ r: RoutedTranscript) { lock.lock(); items.append(r); lock.unlock() }
    var all: [RoutedTranscript] { lock.lock(); defer { lock.unlock() }; return items }
}

@Suite struct STTRouterTests {
    let chunkA = AudioChunk(samples: Array(repeating: 1, count: 640), startMs: 0)
    let chunkB = AudioChunk(samples: Array(repeating: 2, count: 640), startMs: 40)

    func run(primary: FakeSTT, fallbacks: [FakeSTT], timeout: Double = 0.15) async throws -> (RoutedTranscript, RoutedBox) {
        let box = RoutedBox()
        let router = STTRouter(primary: primary, fallbacks: fallbacks, timeout: timeout, onRouted: { box.add($0) })
        let session = try await router.begin(STTOptions())
        session.append(chunkA); session.append(chunkB)
        let t = try await session.finish()
        let routed = try #require(box.all.last)
        #expect(routed.transcript == t)
        return (routed, box)
    }

    @Test func primaryOKNoFallback() async throws {
        let primary = FakeSTT(id: .groq, .ok("привет"))
        let fb = FakeSTT(id: .gigaAM, .ok("запасной"))
        let (r, _) = try await run(primary: primary, fallbacks: [fb])
        #expect(r.transcript.text == "привет")
        #expect(r.fallbackUsed == false)
        #expect(fb.finishCalls == 0)
        #expect(primary.receivedSamples.count == 1280)
    }

    @Test(arguments: [STTError.noNetwork, .http(500, "boom"), .unauthorized, .rateLimited, .outOfCredit, .badResponse("x")])
    func primaryFinishErrorUsesFallback(error: STTError) async throws {
        let primary = FakeSTT(id: .groq, .failFinish(error))
        let fb = FakeSTT(id: .gigaAM, .ok("запасной"))
        let (r, _) = try await run(primary: primary, fallbacks: [fb])
        #expect(r.transcript.text == "запасной")
        #expect(r.fallbackUsed)
        #expect(r.primaryError == error)
        // The same audio, in order, went to the fallback.
        #expect(fb.receivedSamples == Array(repeating: 1, count: 640) + Array(repeating: 2, count: 640))
    }

    @Test func primaryBeginFailureUsesFallback() async throws {
        let primary = FakeSTT(id: .groq, .failBegin(.noNetwork))
        let fb = FakeSTT(id: .gigaAM, .ok("запасной"))
        let (r, _) = try await run(primary: primary, fallbacks: [fb])
        #expect(r.fallbackUsed)
        #expect(r.primaryError == .noNetwork)
        #expect(fb.receivedSamples.count == 1280)
    }

    @Test func slowPrimaryTimesOutAndIsCancelled() async throws {
        let primary = FakeSTT(id: .groq, .slow(seconds: 30, text: "поздно"))
        let fb = FakeSTT(id: .gigaAM, .ok("запасной"))
        let start = Date()
        let (r, _) = try await run(primary: primary, fallbacks: [fb], timeout: 0.15)
        let elapsed = Date().timeIntervalSince(start)
        #expect(r.transcript.text == "запасной")
        #expect(r.fallbackUsed)
        #expect(r.primaryError == .timeout)
        // ponytail: loose bound, CI runners stall ~1.5 s under load; 30 s primary proves it was not awaited.
        #expect(elapsed < 10)
        #expect(primary.wasCancelled)
    }

    @Test func slowPrimaryWithoutFallbackIsAwaited() async throws {
        let primary = FakeSTT(id: .groq, .slow(seconds: 0.4, text: "длинная диктовка"))
        let (r, _) = try await run(primary: primary, fallbacks: [], timeout: 0.15)
        #expect(r.transcript.text == "длинная диктовка")
    }

    @Test func primaryJustInsideTimeoutIsKept() async throws {
        let primary = FakeSTT(id: .groq, .slow(seconds: 0.05, text: "успел"))
        let fb = FakeSTT(id: .gigaAM, .ok("запасной"))
        let (r, _) = try await run(primary: primary, fallbacks: [fb], timeout: 1.0)
        #expect(r.transcript.text == "успел")
        #expect(!r.fallbackUsed)
    }

    @Test func missingModelSkipsToSecondFallback() async throws {
        let primary = FakeSTT(id: .groq, .failFinish(.noNetwork))
        let giga = FakeSTT(id: .gigaAM, .failBegin(.modelMissing("gigaam")))
        let cloud2 = FakeSTT(id: .openRouter, .ok("второй облачный"))
        let (r, _) = try await run(primary: primary, fallbacks: [giga, cloud2])
        #expect(r.transcript.text == "второй облачный")
        #expect(r.fallbackUsed)
        #expect(cloud2.receivedSamples.count == 1280)
    }

    @Test func allFailThrowsPrimaryError() async throws {
        let primary = FakeSTT(id: .groq, .failFinish(.http(503, "down")))
        let fb = FakeSTT(id: .gigaAM, .failBegin(.modelMissing("gigaam")))
        let router = STTRouter(primary: primary, fallbacks: [fb], timeout: 0.15)
        let session = try await router.begin(STTOptions())
        session.append(chunkA)
        await #expect(throws: STTError.http(503, "down")) { _ = try await session.finish() }
    }

    @Test func noFallbacksRethrows() async throws {
        let primary = FakeSTT(id: .groq, .failFinish(.noNetwork))
        let router = STTRouter(primary: primary, fallbacks: [], timeout: 0.15)
        let session = try await router.begin(STTOptions())
        await #expect(throws: STTError.noNetwork) { _ = try await session.finish() }
    }

    @Test func cancelledIsNotFallenBack() async throws {
        let primary = FakeSTT(id: .groq, .failFinish(.cancelled))
        let fb = FakeSTT(id: .gigaAM, .ok("запасной"))
        let router = STTRouter(primary: primary, fallbacks: [fb], timeout: 0.15)
        let session = try await router.begin(STTOptions())
        await #expect(throws: STTError.cancelled) { _ = try await session.finish() }
        #expect(fb.finishCalls == 0)
    }

    @Test func cancelStopsPrimary() async throws {
        let primary = FakeSTT(id: .groq, .ok("x"))
        let router = STTRouter(primary: primary, fallbacks: [], timeout: 0.15)
        let session = try await router.begin(STTOptions())
        session.cancel()
        #expect(primary.wasCancelled)
    }

    @Test func routerIdIsPrimaryId() {
        let router = STTRouter(primary: FakeSTT(id: .groq, .ok("x")), fallbacks: [])
        #expect(router.id == .groq)
        #expect(router.timeout == 1.5)
    }
}
