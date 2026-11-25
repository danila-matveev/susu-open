import Foundation

public struct UploadedText: Sendable, Equatable {
    public var text: String
    public var language: String?
    public init(text: String, language: String? = nil) { self.text = text; self.language = language }
}

/// Session for providers that take whole files (Groq cannot stream).
/// - `append` buffers audio. When the un-sent audio exceeds `splitAfterSeconds` and a pause has just
///   ended, everything before the current chunk goes out in the background (spec 3.3).
/// - `finish` sends only the tail and joins the texts of all pieces in speech order.
/// Nothing is trimmed here: silence trimming belongs to the audio module, hallucination stripping to T2.1.
public final class ChunkedSTTSession: STTSession, @unchecked Sendable {
    /// Uploads one piece. `previousText` is the text of the piece before it (nil for the first one),
    /// so the provider keeps names consistent across the cut.
    public typealias Upload = @Sendable (_ samples: [Int16], _ previousText: String?) async throws -> UploadedText

    private struct State {
        var pending: [Int16] = []
        var pieces: [Task<UploadedText, Error>] = []
        var totalSamples = 0
        var finished = false
        var cancelled = false
        /// Text of the latest piece that already came back, and its index.
        var lastDone: (index: Int, text: String)?
    }

    private let lock = NSLock()
    private var state = State()
    private let provider: ProviderID
    private let model: String
    private let clock: any SusuClock
    private let splitSamples: Int
    private let pauseEnded: (@Sendable (AudioChunk) -> Bool)?
    private let upload: Upload
    public let partials: AsyncStream<String>

    public init(provider: ProviderID, model: String, clock: any SusuClock = SystemClock(),
                splitAfterSeconds: Double = 20,
                pauseEnded: (@Sendable (AudioChunk) -> Bool)? = nil,
                upload: @escaping Upload) {
        self.provider = provider; self.model = model; self.clock = clock
        self.splitSamples = Int(splitAfterSeconds * Double(AudioChunk.sampleRate))
        self.pauseEnded = pauseEnded; self.upload = upload
        partials = AsyncStream { $0.finish() }   // Groq has no partial text
    }

    public func append(_ chunk: AudioChunk) {
        // Ask the detector for every chunk (it keeps its own state), outside the lock.
        let pause = pauseEnded?(chunk) ?? false
        lock.lock(); defer { lock.unlock() }
        guard !state.finished, !state.cancelled else { return }
        if pause, state.pending.count > splitSamples {
            // The chunk that ended the pause is speech: it starts the next piece.
            let piece = state.pending
            state.pending = []
            let upload = self.upload
            let previous = state.pieces.last, index = state.pieces.count
            // Pieces go out ≥ 20 s apart, so waiting for the previous one costs nothing in practice.
            state.pieces.append(Task { [weak self] in
                let prev = try? await previous?.value
                let r = try await upload(piece, prev?.text)
                self?.lock.withLock { if (self?.state.lastDone?.index ?? -1) < index { self?.state.lastDone = (index, r.text) } }
                return r
            })
        }
        state.pending.append(contentsOf: chunk.samples)
        state.totalSamples += chunk.samples.count
    }

    public func finish() async throws -> Transcript {
        guard let (tail, pieces, total, lastDone) = takeForFinish() else { throw STTError.cancelled }
        // The tail must not wait: it gets the previous text only if that piece is already back.
        let previousText = lastDone?.index == pieces.count - 1 ? lastDone?.text : nil

        let upload = self.upload, clock = self.clock
        let tailTask: Task<(UploadedText, Int)?, Error>? = tail.isEmpty ? nil : Task {
            let t0 = clock.now()
            let r = try await upload(tail, previousText)
            return (r, Int(((clock.now() - t0) * 1000).rounded()))
        }
        var texts: [UploadedText] = []
        do {
            for p in pieces { texts.append(try await p.value) }
            var networkMs = 0
            if let tailTask, let (r, ms) = try await tailTask.value { texts.append(r); networkMs = ms }
            let joined = texts.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            return Transcript(text: joined, language: texts.compactMap(\.language).first, provider: provider,
                              model: model, audioSeconds: Double(total) / Double(AudioChunk.sampleRate),
                              networkMs: networkMs)
        } catch {
            for p in pieces { p.cancel() }
            tailTask?.cancel()
            throw (error as? STTError) ?? OpenAICompatibleTranscription.map(transportError: error)
        }
    }

    private func takeForFinish() -> (tail: [Int16], pieces: [Task<UploadedText, Error>], total: Int,
                                     lastDone: (index: Int, text: String)?)? {
        lock.withLock {
            if state.cancelled { return nil }
            state.finished = true
            defer { state.pending = [] }
            return (state.pending, state.pieces, state.totalSamples, state.lastDone)
        }
    }

    public func cancel() {
        lock.lock()
        state.cancelled = true
        let pieces = state.pieces
        state.pieces = []
        state.pending = []
        lock.unlock()
        for p in pieces { p.cancel() }
    }
}
