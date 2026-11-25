import CryptoKit
import Foundation

public struct ModelFile: Sendable, Equatable {
    public var name: String
    public var url: URL
    public var sha256: String
    public var size: Int64
    public init(name: String, url: URL, sha256: String, size: Int64) {
        self.name = name; self.url = url; self.sha256 = sha256; self.size = size
    }
}

public enum ModelDownloadError: Error, Equatable {
    case http(Int, String)
    case checksumMismatch(String)
    case sourceMissing(String)
}

/// GigaAM v3 e2e RNN-T int8 from Hugging Face, pinned to one commit so the checksums stay valid.
public enum GigaAMModel {
    public static let revision = "322c3b29492673eb7d0b434bfa9dfb8653e34d02"

    private static func file(_ name: String, _ sha: String, _ size: Int64) -> ModelFile {
        ModelFile(name: name,
                  url: URL(string: "https://huggingface.co/istupakov/gigaam-v3-onnx/resolve/\(revision)/\(name)")!,
                  sha256: sha, size: size)
    }

    public static let files: [ModelFile] = [
        file(GigaAMModelFiles.encoder, "4e0e076a6076cd110277e529b8ac8f32cd5297f7fbebad5341ae8ddb7d00817b", 224_570_477),
        file(GigaAMModelFiles.decoder, "89014e134865615b91e037157e46e389b1271e6072460efc010ea08e61e23146", 1_159_170),
        file(GigaAMModelFiles.joint, "ade116563dbf66e503b0994efab6b5861412743e52bf31c39fc3fffa3783d5d1", 687_791),
        file(GigaAMModelFiles.vocab, "39abae20e692998290c574e606f11a9edef2902a1995463fcff63d1490cf22b7", 13_354),
        file(GigaAMModelFiles.config, "0641fcf73f4af791c73f05083e38a658ff5dcbee3534a0c61396c10f4b97f0fe", 135),
    ]
}

/// A running download: overall progress 0...1 and the final model directory.
public struct ModelDownload: Sendable {
    public let progress: AsyncStream<Double>
    public let task: Task<URL, Error>
}

/// Downloads a model file set into `<data>/models/<name>/` with a SHA-256 check (spec 2.1, 5.1).
public final class ModelDownloader: Sendable {
    public let modelsRoot: URL
    private let session: URLSession

    /// - Parameter modelsRoot: the `<data>/models` folder.
    public init(modelsRoot: URL, session: URLSession = .shared) {
        self.modelsRoot = modelsRoot; self.session = session
    }

    public func directory(for name: String) -> URL { modelsRoot.appendingPathComponent(name, isDirectory: true) }

    public var gigaAMDirectory: URL { directory(for: GigaAMModelFiles.directoryName) }

    public func downloadGigaAM() -> ModelDownload {
        download(name: GigaAMModelFiles.directoryName, files: GigaAMModel.files)
    }

    /// Dev helper: copies the files from a local folder (for example the Hugging Face cache snapshot).
    @discardableResult
    public func importLocalGigaAM(from source: URL) throws -> URL {
        try importLocal(name: GigaAMModelFiles.directoryName, files: GigaAMModel.files, from: source)
    }

    /// Cheap check: every file exists with the expected size (checksums are verified on download/import).
    public func isInstalled(name: String, files: [ModelFile]) -> Bool {
        let dir = directory(for: name)
        return files.allSatisfy { f in
            let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(f.name).path)
            return (attrs?[.size] as? NSNumber)?.int64Value == f.size
        }
    }

    public func download(name: String, files: [ModelFile]) -> ModelDownload {
        let (stream, cont) = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let total = Double(max(1, files.reduce(0) { $0 + $1.size }))
        let dir = directory(for: name)
        let session = self.session
        let task = Task<URL, Error> {
            defer { cont.finish() }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var done: Int64 = 0
            for f in files {
                try Task.checkCancellation()
                let dest = dir.appendingPathComponent(f.name)
                if (try? Self.sha256(of: dest)) == f.sha256 {
                    done += f.size
                    cont.yield(Double(done) / total)
                    continue
                }
                var request = URLRequest(url: f.url)
                request.setValue("Susu/1.0", forHTTPHeaderField: "User-Agent")
                let base = done
                let delegate = ProgressDelegate { written in cont.yield(min(1, Double(base + written) / total)) }
                let (tmp, response) = try await session.download(for: request, delegate: delegate)
                defer { try? FileManager.default.removeItem(at: tmp) }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw ModelDownloadError.http(http.statusCode, f.name)
                }
                guard try Self.sha256(of: tmp) == f.sha256 else { throw ModelDownloadError.checksumMismatch(f.name) }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                done += f.size
                cont.yield(Double(done) / total)
            }
            return dir
        }
        return ModelDownload(progress: stream, task: task)
    }

    @discardableResult
    public func importLocal(name: String, files: [ModelFile], from source: URL) throws -> URL {
        let dir = directory(for: name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files {
            let src = source.appendingPathComponent(f.name).resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: src.path) else { throw ModelDownloadError.sourceMissing(f.name) }
            guard try Self.sha256(of: src) == f.sha256 else { throw ModelDownloadError.checksumMismatch(f.name) }
            let dest = dir.appendingPathComponent(f.name)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: src, to: dest)
        }
        return dir
    }

    /// Streaming SHA-256 (hex), 4 MB at a time.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let onWritten: @Sendable (Int64) -> Void
        init(_ onWritten: @escaping @Sendable (Int64) -> Void) { self.onWritten = onWritten }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            onWritten(totalBytesWritten)
        }
    }
}
