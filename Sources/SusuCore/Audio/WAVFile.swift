import AVFoundation
import Foundation

public enum WAVError: Error, Equatable {
    case cannotOpen(String)
    case conversionFailed(String)
}

/// Streaming writer for 16-bit mono 16 kHz PCM WAV. Not thread-safe: use from one queue.
/// The header is written up front with zero sizes and patched in `finalize()`.
public final class WAVWriter {
    public static let headerSize = 44
    public let url: URL
    public private(set) var sampleCount = 0
    private var handle: FileHandle?

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(sampleCount: 0)),
              let h = FileHandle(forWritingAtPath: url.path)
        else { throw WAVError.cannotOpen(url.path) }
        try h.seekToEnd()
        handle = h
    }

    public func append(_ samples: [Int16]) throws {
        guard let handle, !samples.isEmpty else { return }
        let data = samples.withUnsafeBufferPointer { buf -> Data in
            var d = Data(capacity: buf.count * 2)
            for s in buf { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
            return d
        }
        try handle.write(contentsOf: data)
        sampleCount += samples.count
    }

    /// Patches the RIFF and data sizes and closes the file. Safe to call twice.
    public func finalize() throws {
        guard let handle else { return }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(sampleCount: sampleCount))
        try handle.close()
        self.handle = nil
    }

    /// 44-byte RIFF/WAVE header for 16 kHz mono 16-bit PCM.
    public static func header(sampleCount: Int) -> Data {
        let dataBytes = UInt32(sampleCount * 2)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)                                  // PCM
        u16(1)                                  // mono
        u32(UInt32(AudioChunk.sampleRate))
        u32(UInt32(AudioChunk.sampleRate * 2))  // byte rate
        u16(2)                                  // block align
        u16(16)                                 // bits per sample
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }
}

public enum WAVFile {
    /// Writes a complete 16 kHz mono Int16 WAV.
    public static func write(samples: [Int16], to url: URL) throws {
        let w = try WAVWriter(url: url)
        try w.append(samples)
        try w.finalize()
    }

    /// Reads any audio file AVFoundation understands and returns 16 kHz mono Int16 samples
    /// (resampling and downmixing when needed).
    public static func readSamples(_ url: URL) throws -> [Int16] {
        let probe: AVAudioFile
        do { probe = try AVAudioFile(forReading: url) } catch { throw WAVError.cannotOpen(url.path) }
        let fmt = probe.fileFormat
        if fmt.sampleRate == Double(AudioChunk.sampleRate) && fmt.channelCount == 1 {
            return try readDirect(url)
        }
        return try readConverting(probe)
    }

    private static func readDirect(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        var out: [Int16] = []
        out.reserveCapacity(Int(file.length))
        let block: AVAudioFrameCount = 32_768
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block) else {
            throw WAVError.conversionFailed("buffer")
        }
        while file.framePosition < file.length {
            try file.read(into: buf, frameCount: block)
            if buf.frameLength == 0 { break }
            out.append(contentsOf: UnsafeBufferPointer(start: buf.int16ChannelData![0], count: Int(buf.frameLength)))
        }
        return out
    }

    private static func readConverting(_ file: AVAudioFile) throws -> [Int16] {
        guard let conv = PCM16kConverter(inputFormat: file.processingFormat) else {
            throw WAVError.conversionFailed("unsupported format \(file.processingFormat)")
        }
        let block: AVAudioFrameCount = 16_384
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block) else {
            throw WAVError.conversionFailed("buffer")
        }
        var out: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: buf, frameCount: block)
            if buf.frameLength == 0 { break }
            out.append(contentsOf: conv.convert(buf))
        }
        out.append(contentsOf: conv.flush())
        return out
    }
}

/// Converts arbitrary PCM buffers to 16 kHz mono Int16, keeping resampler state between calls.
final class PCM16kConverter {
    // ponytail: immutable after init; CI SDK does not mark AVAudioFormat Sendable yet.
    nonisolated(unsafe) static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: Double(AudioChunk.sampleRate),
        channels: 1, interleaved: true)!
    private let converter: AVAudioConverter
    private let ratio: Double

    init?(inputFormat: AVAudioFormat) {
        guard let c = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else { return nil }
        converter = c
        ratio = Self.outputFormat.sampleRate / inputFormat.sampleRate
    }

    func convert(_ input: AVAudioPCMBuffer) -> [Int16] {
        let cap = AVAudioFrameCount(Double(input.frameLength) * ratio) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: cap) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        return Self.samples(out)
    }

    /// Drains what the resampler still holds (end of recording / end of file).
    func flush() -> [Int16] {
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: 4096) else { return [] }
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        return Self.samples(out)
    }

    private static func samples(_ b: AVAudioPCMBuffer) -> [Int16] {
        guard b.frameLength > 0, let p = b.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: p[0], count: Int(b.frameLength)))
    }
}
