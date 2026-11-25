import AVFoundation
import Foundation

/// Wispr stores dictation audio as WAV blobs; Susu keeps m4a (AAC, mono, ~32 kbps, spec 5.1).
public enum WisprAudio {
    public static func convertWAVToM4A(wav: Data, workDirectory: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = workDirectory.appendingPathComponent("wav-\(UUID().uuidString).wav")
        try wav.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? FileManager.default.removeItem(at: destination)

        do {
            let input = try AVAudioFile(forReading: tmp)
            let format = input.processingFormat
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: Int(format.channelCount),
                AVEncoderBitRateKey: 32_000 * Int(format.channelCount),
            ]
            var output: AVAudioFile? = try AVAudioFile(forWriting: destination, settings: settings)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
                throw WisprError.snapshotFailed("no audio buffer")
            }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output?.write(from: buffer)
            }
            output = nil  // closing the file finalizes the m4a
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
