// E2E without the Microphone permission: SUSU_E2E_AUDIO=<path> makes the app "hear" that file at speech speed,
// then silence until the key is released. Everything after the mic (hotkey, STT, cleanup, insert, history) is real.
import Foundation
import SusuCore

final class FileMic: DictationMic, @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var chunks: [AudioChunk] = []

    init(path: String) { self.path = path }

    func start(onChunk: (@Sendable (AudioChunk) -> Void)?, onLevel: (@Sendable (Float) -> Void)?,
               onMicConfirmed: (@Sendable () -> Void)?) throws {
        let samples = (try? WAVFile.readSamples(URL(fileURLWithPath: path))) ?? []
        lock.withLock { chunks = [] }
        onMicConfirmed?()
        let n = AudioChunk.samplesPer40ms
        var offset = 0
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.susu.filemic"))
        t.schedule(deadline: .now(), repeating: .milliseconds(40))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let part = offset < samples.count ? Array(samples[offset..<min(offset + n, samples.count)]) : [Int16](repeating: 0, count: n)
            let chunk = AudioChunk(samples: part + [Int16](repeating: 0, count: n - part.count), startMs: offset / 16)
            offset += n
            lock.withLock { chunks.append(chunk) }
            onChunk?(chunk)
            onLevel?(Float(part.map { abs(Int($0)) }.max() ?? 0) / 32768)
        }
        lock.withLock { timer = t }
        t.resume()
    }

    func stop() -> MicRecording {
        let (t, all) = lock.withLock { (timer, chunks) }
        t?.cancel()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).wav")
        try? WAVFile.write(samples: all.flatMap(\.samples), to: url)
        return MicRecording(chunks: all, wavURL: url)
    }
}
