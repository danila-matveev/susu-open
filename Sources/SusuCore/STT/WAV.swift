import Foundation

/// Minimal 16-bit PCM WAV reader/writer (16 kHz mono is what the whole STT path uses).
public enum WAV {
    public static func encode(_ samples: [Int16], sampleRate: Int = AudioChunk.sampleRate) -> Data {
        let dataSize = samples.count * 2
        var d = Data(capacity: 44 + dataSize)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        samples.withUnsafeBytes { d.append(contentsOf: $0) }   // Apple platforms are little-endian
        return d
    }

    public struct Decoded: Equatable {
        public var samples: [Int16]
        public var sampleRate: Int
        public var channels: Int
    }

    /// Reads 16-bit PCM WAV. Returns nil for anything else.
    public static func decode(_ data: Data) -> Decoded? {
        let b = [UInt8](data)
        guard b.count >= 12, String(decoding: b[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: b[8..<12], as: UTF8.self) == "WAVE" else { return nil }
        func le32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        func le16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        var pos = 12
        var rate = 0, channels = 0, bits = 0, format = 0
        while pos + 8 <= b.count {
            let id = String(decoding: b[pos..<pos + 4], as: UTF8.self)
            var size = le32(pos + 4)
            let body = pos + 8
            if id == "fmt ", body + 16 <= b.count {
                format = le16(body); channels = le16(body + 2); rate = le32(body + 4); bits = le16(body + 14)
            } else if id == "data" {
                guard format == 1, bits == 16, channels > 0 else { return nil }
                size = min(size, b.count - body)   // streamed files may carry a bogus size
                let n = size / 2
                var out = [Int16](repeating: 0, count: n)
                for i in 0..<n { out[i] = Int16(bitPattern: UInt16(b[body + 2 * i]) | UInt16(b[body + 2 * i + 1]) << 8) }
                return Decoded(samples: out, sampleRate: rate, channels: channels)
            }
            pos = body + size + (size & 1)
        }
        return nil
    }
}
