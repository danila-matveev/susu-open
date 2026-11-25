import AVFoundation
import Foundation

public struct MicInputDevice: Sendable, Equatable {
    public var uid: String
    public var name: String
    public var isBuiltIn: Bool
    public init(uid: String, name: String, isBuiltIn: Bool = false) {
        self.uid = uid; self.name = name; self.isBuiltIn = isBuiltIn
    }
}

public enum MicRecorderError: Error, Equatable {
    case alreadyRecording
    case noInput
    case converterUnavailable
    case engineFailed(String)
}

public struct MicRecording: Sendable {
    /// All 40 ms chunks (the last one may be shorter).
    public var chunks: [AudioChunk]
    /// WAV of the whole recording in the temp folder; nil if the file could not be created.
    public var wavURL: URL?
    public var samples: [Int16] { chunks.flatMap(\.samples) }
    public var durationMs: Int { chunks.reduce(0) { $0 + $1.durationMs } }
    public init(chunks: [AudioChunk], wavURL: URL?) { self.chunks = chunks; self.wavURL = wavURL }
}

/// Microphone capture: AVAudioEngine tap -> 16 kHz mono Int16 -> 40 ms chunks (spec 3.2).
/// Callbacks run on the audio thread; keep them light (hop to another queue for real work).
public final class MicRecorder: @unchecked Sendable {
    public typealias Handlers = (
        onChunk: (@Sendable (AudioChunk) -> Void)?,
        onLevel: (@Sendable (Float) -> Void)?,
        onMicConfirmed: (@Sendable () -> Void)?
    )

    private let lock = NSLock()
    // ponytail: one engine for the app's life. A fresh AVAudioEngine per dictation built and tore down
    // a CoreAudio aggregate device each time; 1 run in ~90 hung in stop() and crashed the HAL IO thread.
    private var engine: AVAudioEngine?
    private var session: Session?
    private var priority: [String]
    private let tempDirectory: URL

    /// - Parameter devicePriority: device UIDs (or names) in order of preference; empty = system default.
    public init(devicePriority: [String] = [],
                tempDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("susu-dictation")) {
        priority = devicePriority
        self.tempDirectory = tempDirectory
    }

    public var devicePriority: [String] {
        get { lock.withLock { priority } }
        set { lock.withLock { priority = newValue } }
    }

    public var isRecording: Bool { lock.withLock { session != nil } }

    /// Opens the mic and starts delivering audio. `onMicConfirmed` fires once, when the first
    /// 40 ms chunk has arrived (the pill then switches its bars to full opacity).
    public func start(onChunk: (@Sendable (AudioChunk) -> Void)? = nil,
                      onLevel: (@Sendable (Float) -> Void)? = nil,
                      onMicConfirmed: (@Sendable () -> Void)? = nil) throws {
        let prio: [String] = try lock.withLock {
            if session != nil { throw MicRecorderError.alreadyRecording }
            return priority
        }
        #if os(iOS)
        let avs = AVAudioSession.sharedInstance()
        try? avs.setCategory(.record, mode: .measurement)
        try? avs.setActive(true)
        #endif

        let engine = lock.withLock { () -> AVAudioEngine in
            if let e = self.engine { return e }
            let e = AVAudioEngine(); self.engine = e; return e
        }
        #if os(macOS)
        MicDevices.select(priority: prio, on: engine)
        #endif
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicRecorderError.noInput }
        guard let converter = PCM16kConverter(inputFormat: format) else { throw MicRecorderError.converterUnavailable }

        let wavURL = tempDirectory.appendingPathComponent("dictation-\(UUID().uuidString).wav")
        let s = Session(converter: converter, wavURL: wavURL,
                        onChunk: onChunk, onLevel: onLevel, onConfirmed: onMicConfirmed)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [s] buffer, _ in
            s.process(buffer)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            s.discard()
            lock.withLock { self.engine = nil }   // next start gets a fresh engine
            throw MicRecorderError.engineFailed("\(error)")
        }
        lock.withLock { self.session = s }
    }

    /// Stops capture, flushes the last partial chunk and finalizes the WAV.
    @discardableResult
    public func stop() -> MicRecording {
        let (engine, session) = lock.withLock { () -> (AVAudioEngine?, Session?) in
            defer { self.session = nil }
            return (self.session == nil ? nil : self.engine, self.session)
        }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        return session?.finish() ?? MicRecording(chunks: [], wavURL: nil)
    }

    #if os(macOS)
    /// Input devices for the settings screen (uid is stable across reboots).
    public static func availableInputDevices() -> [(uid: String, name: String)] {
        MicDevices.all().map { ($0.uid, $0.name) }
    }
    #endif
}

/// State touched by the audio thread. Everything goes through `lock`.
private final class Session: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: PCM16kConverter
    private var slicer = ChunkSlicer()
    private var meter = LevelMeter()
    private var chunks: [AudioChunk] = []
    private var confirmed = false
    private var finished = false
    private let writeQueue = DispatchQueue(label: "susu.wav-writer")
    private var writer: WAVWriter?
    private let wavURL: URL
    private let onChunk: (@Sendable (AudioChunk) -> Void)?
    private let onLevel: (@Sendable (Float) -> Void)?
    private let onConfirmed: (@Sendable () -> Void)?

    init(converter: PCM16kConverter, wavURL: URL,
         onChunk: (@Sendable (AudioChunk) -> Void)?, onLevel: (@Sendable (Float) -> Void)?,
         onConfirmed: (@Sendable () -> Void)?) {
        self.converter = converter
        self.wavURL = wavURL
        self.onChunk = onChunk; self.onLevel = onLevel; self.onConfirmed = onConfirmed
        writeQueue.async { [self] in writer = try? WAVWriter(url: wavURL) }
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        let samples = converter.convert(buffer)
        guard !samples.isEmpty else { return }
        deliver(samples, flushTail: false)
    }

    private func deliver(_ samples: [Int16], flushTail: Bool) {
        var newChunks: [AudioChunk] = []
        var levels: [Float] = []
        var firstTime = false
        lock.lock()
        if finished { lock.unlock(); return }
        newChunks = slicer.append(samples)
        if flushTail, let tail = slicer.flush() { newChunks.append(tail) }
        chunks.append(contentsOf: newChunks)
        levels = meter.feed(samples)
        if !confirmed, !newChunks.isEmpty { confirmed = true; firstTime = true }
        lock.unlock()

        writeQueue.async { [self] in try? writer?.append(samples) }
        if firstTime { onConfirmed?() }
        for c in newChunks { onChunk?(c) }
        for l in levels { onLevel?(l) }
    }

    func finish() -> MicRecording {
        deliver(converter.flush(), flushTail: true)
        lock.lock()
        finished = true
        let all = chunks
        lock.unlock()
        let url: URL? = writeQueue.sync {
            guard let w = writer else { return nil }
            return (try? w.finalize()) != nil ? wavURL : nil
        }
        return MicRecording(chunks: all, wavURL: url)
    }

    func discard() {
        lock.withLock { finished = true }
        writeQueue.sync {
            try? writer?.finalize()
            try? FileManager.default.removeItem(at: wavURL)
        }
    }
}
