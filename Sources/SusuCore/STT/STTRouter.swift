import Foundation

/// A transcript plus how it was obtained (spec 3.3: the history marks "fallback path").
/// `Transcript` itself is fixed in Interfaces, so the routing info wraps it.
public struct RoutedTranscript: Sendable, Equatable {
    public var transcript: Transcript
    /// True when the primary provider failed or was too slow and another one produced the text.
    public var fallbackUsed: Bool
    /// Why the primary was abandoned (nil when it answered).
    public var primaryError: STTError?
    public init(transcript: Transcript, fallbackUsed: Bool, primaryError: STTError? = nil) {
        self.transcript = transcript; self.fallbackUsed = fallbackUsed; self.primaryError = primaryError
    }
}

/// Primary cloud provider with one fallback path (spec 3.3): no network / HTTP error /
/// no answer within `timeout` after `finish()` → the same audio goes to the first usable
/// fallback (GigaAM when its model is on disk, else a second cloud provider).
public final class STTRouter: SpeechToText {
    public let primary: any SpeechToText
    public let fallbacks: [any SpeechToText]
    public let timeout: TimeInterval
    let clock: any SusuClock
    let onRouted: (@Sendable (RoutedTranscript) -> Void)?

    public var id: ProviderID { primary.id }

    /// - Parameter fallbacks: tried in order; a fallback whose `begin` throws (for example
    ///   `modelMissing`) is skipped.
    /// - Parameter onRouted: called once per finished session with the routing info.
    public init(primary: any SpeechToText, fallbacks: [any SpeechToText], timeout: TimeInterval = 1.5,
                clock: any SusuClock = SystemClock(), onRouted: (@Sendable (RoutedTranscript) -> Void)? = nil) {
        self.primary = primary; self.fallbacks = fallbacks; self.timeout = timeout
        self.clock = clock; self.onRouted = onRouted
    }

    public func prewarm() async { await primary.prewarm() }

    public func begin(_ options: STTOptions) async throws -> any STTSession {
        var session: (any STTSession)?
        var beginError: STTError?
        do { session = try await primary.begin(options) } catch { beginError = Self.asSTTError(error) }
        return STTRouterSession(router: self, options: options, primarySession: session, beginError: beginError)
    }

    static func asSTTError(_ error: Error) -> STTError {
        if let e = error as? STTError { return e }
        if error is CancellationError { return .cancelled }
        if let u = error as? URLError {
            switch u.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timeout
            default: return .noNetwork
            }
        }
        return .badResponse(String(describing: error))
    }
}

public final class STTRouterSession: STTSession, @unchecked Sendable {
    private let router: STTRouter
    private let options: STTOptions
    private let primarySession: (any STTSession)?
    private let beginError: STTError?
    private let lock = NSLock()
    private var chunks: [AudioChunk] = []

    init(router: STTRouter, options: STTOptions, primarySession: (any STTSession)?, beginError: STTError?) {
        self.router = router; self.options = options
        self.primarySession = primarySession; self.beginError = beginError
    }

    public var partials: AsyncStream<String> { primarySession?.partials ?? AsyncStream { $0.finish() } }

    public func append(_ chunk: AudioChunk) {
        lock.withLock { chunks.append(chunk) }
        primarySession?.append(chunk)
    }

    public func cancel() { primarySession?.cancel() }

    public func finish() async throws -> Transcript {
        try await finishRouted().transcript
    }

    public func finishRouted() async throws -> RoutedTranscript {
        var primaryError: STTError
        if let primarySession {
            do {
                // No fallback to switch to: waiting longer beats losing a long dictation (the provider has its own timeout).
                let t = router.fallbacks.isEmpty ? try await primarySession.finish()
                    : try await Self.withDeadline(seconds: router.timeout, clock: router.clock) { try await primarySession.finish() }
                return report(RoutedTranscript(transcript: t, fallbackUsed: false))
            } catch {
                primaryError = STTRouter.asSTTError(error)
                primarySession.cancel()
            }
        } else {
            primaryError = beginError ?? .noNetwork
        }
        // The user's own cancel is never "fixed" by another provider.
        if primaryError == .cancelled || Task.isCancelled { throw STTError.cancelled }

        let audio = lock.withLock { chunks }
        for fallback in router.fallbacks {
            do {
                let session = try await fallback.begin(options)
                for chunk in audio { session.append(chunk) }
                let t = try await session.finish()
                return report(RoutedTranscript(transcript: t, fallbackUsed: true, primaryError: primaryError))
            } catch {
                if Task.isCancelled { throw STTError.cancelled }
                continue
            }
        }
        throw primaryError
    }

    private func report(_ r: RoutedTranscript) -> RoutedTranscript {
        router.onRouted?(r)
        return r
    }

    /// Runs `operation`; if it does not return within `seconds` the call throws `.timeout`
    /// right away (the operation is cancelled but not awaited, so a provider that ignores
    /// cancellation cannot hold the fallback back).
    static func withDeadline<T: Sendable>(seconds: TimeInterval, clock: any SusuClock,
                                          operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = Gate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                gate.install(cont)
                let op = Task {
                    do { gate.resolve(.success(try await operation())) } catch { gate.resolve(.failure(error)) }
                }
                let timer = Task {
                    do { try await clock.sleep(seconds: seconds); gate.resolve(.failure(STTError.timeout)) } catch {}
                }
                gate.onResolved { op.cancel(); timer.cancel() }
            }
        } onCancel: {
            gate.resolve(.failure(STTError.cancelled))
        }
    }

    /// One-shot hand-off between the operation, the timer and outer cancellation.
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<T, Error>?
        private var pending: Result<T, Error>?
        private var done = false
        private var cleanup: (@Sendable () -> Void)?

        func install(_ c: CheckedContinuation<T, Error>) {
            lock.lock()
            if let pending { lock.unlock(); c.resume(with: pending); return }
            cont = c; lock.unlock()
        }
        func onResolved(_ f: @escaping @Sendable () -> Void) {
            lock.lock()
            if done { lock.unlock(); f(); return }
            cleanup = f; lock.unlock()
        }
        func resolve(_ r: Result<T, Error>) {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            let c = cont; cont = nil
            if c == nil { pending = r }
            let f = cleanup; cleanup = nil
            lock.unlock()
            c?.resume(with: r)
            f?()
        }
    }
}
