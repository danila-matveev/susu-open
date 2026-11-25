import CryptoKit
import Foundation
import Testing
@testable import SusuCore

@Suite struct ModelDownloaderTests {
    struct Fixture {
        let root: URL, source: URL, files: [ModelFile]
        init(corruptSecond: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("susu-dl-\(UUID().uuidString)")
            source = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            var list: [ModelFile] = []
            for (i, name) in ["a.bin", "b.bin"].enumerated() {
                let data = Data((0..<(100_000 + i)).map { UInt8(truncatingIfNeeded: $0 &* (i + 3)) })
                let url = source.appendingPathComponent(name)
                try data.write(to: url)
                let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                list.append(ModelFile(name: name, url: url, sha256: (corruptSecond && i == 1) ? String(repeating: "0", count: 64) : sha,
                                      size: Int64(data.count)))
            }
            files = list
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func downloadsVerifiesAndReportsProgress() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let dl = ModelDownloader(modelsRoot: fx.root.appendingPathComponent("models"))
        let d = dl.download(name: "m", files: fx.files)
        let collector = Task { var last = 0.0; var count = 0; for await p in d.progress { #expect(p >= last); last = p; count += 1 }; return (last, count) }
        let dir = try await d.task.value
        let (last, count) = await collector.value
        #expect(last == 1.0)
        #expect(count >= 2)
        #expect(dl.isInstalled(name: "m", files: fx.files))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.bin").path))
    }

    @Test func checksumMismatchFailsAndLeavesNoFile() async throws {
        let fx = try Fixture(corruptSecond: true); defer { fx.cleanup() }
        let dl = ModelDownloader(modelsRoot: fx.root.appendingPathComponent("models"))
        let d = dl.download(name: "m", files: fx.files)
        await #expect(throws: ModelDownloadError.checksumMismatch("b.bin")) { _ = try await d.task.value }
        #expect(!FileManager.default.fileExists(atPath: dl.directory(for: "m").appendingPathComponent("b.bin").path))
        #expect(!dl.isInstalled(name: "m", files: fx.files))
    }

    @Test func secondRunSkipsFilesAlreadyPresent() async throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let dl = ModelDownloader(modelsRoot: fx.root.appendingPathComponent("models"))
        _ = try await dl.download(name: "m", files: fx.files).task.value
        // Remove the source: a second run must succeed without touching the network/source.
        try FileManager.default.removeItem(at: fx.source)
        _ = try await dl.download(name: "m", files: fx.files).task.value
    }

    @Test func importLocalCopiesAndChecks() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let dl = ModelDownloader(modelsRoot: fx.root.appendingPathComponent("models"))
        let dir = try dl.importLocal(name: "m", files: fx.files, from: fx.source)
        #expect(dl.isInstalled(name: "m", files: fx.files))
        #expect(dir.lastPathComponent == "m")
    }

    @Test func importLocalRejectsBadChecksumAndMissingFile() throws {
        let bad = try Fixture(corruptSecond: true); defer { bad.cleanup() }
        let dl = ModelDownloader(modelsRoot: bad.root.appendingPathComponent("models"))
        #expect(throws: ModelDownloadError.checksumMismatch("b.bin")) {
            try dl.importLocal(name: "m", files: bad.files, from: bad.source)
        }
        let missing = ModelFile(name: "nope.bin", url: bad.source, sha256: "", size: 1)
        #expect(throws: ModelDownloadError.sourceMissing("nope.bin")) {
            try dl.importLocal(name: "m2", files: [missing], from: bad.source)
        }
    }

    @Test func gigaAMFileSetIsComplete() {
        #expect(GigaAMModel.files.map(\.name).sorted() == GigaAMModelFiles.all.sorted())
        #expect(GigaAMModel.files.allSatisfy { $0.sha256.count == 64 && $0.url.host == "huggingface.co" })
    }
}
