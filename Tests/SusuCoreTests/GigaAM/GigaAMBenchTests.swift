import Foundation
import Testing
@testable import SusuCore

/// Local-only checks against the real model and private clips (never in CI, never in git).
enum GigaAMTestEnv {
    static var testset: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SUSU_TESTSET"]
            ?? NSHomeDirectory() + "/Projects/susu/research-private/stt")
    }
    /// Folder with the int8 files: SUSU_GIGAAM_MODEL, else the newest Hugging Face cache snapshot.
    static var modelDir: URL? {
        if let p = ProcessInfo.processInfo.environment["SUSU_GIGAAM_MODEL"] { return URL(fileURLWithPath: p) }
        let snaps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--istupakov--gigaam-v3-onnx/snapshots")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: snaps, includingPropertiesForKeys: nil)) ?? []
        return dirs.first { GigaAMModelFiles.isPresent(in: $0) }
    }
    static var haveModelAndClips: Bool {
        modelDir != nil && FileManager.default.fileExists(atPath: testset.appendingPathComponent("clips/c01.wav").path)
    }
}

@Suite(.serialized) struct GigaAMBenchTests {
    @Test(.enabled(if: GigaAMTestEnv.haveModelAndClips))
    func smokeOneClip() async throws {
        let giga = GigaAMLocal(modelDir: try #require(GigaAMTestEnv.modelDir))
        let segs = try await giga.transcribe(GigaAMTestEnv.testset.appendingPathComponent("clips/c01.wav"), options: FileSTTOptions())
        let text = segs.map(\.text).joined(separator: " ")
        print("c01:", text)
        #expect(!text.isEmpty)
    }

    @Test(.enabled(if: GigaAMTestEnv.haveModelAndClips))
    func dictationWrapperMatchesFileTranscriber() async throws {
        let giga = GigaAMLocal(modelDir: try #require(GigaAMTestEnv.modelDir))
        let url = GigaAMTestEnv.testset.appendingPathComponent("clips/c01.wav")
        let pcm = try WAVFile.readSamples(url)
        let stt = GigaAMSpeechToText(local: giga)
        let session = try await stt.begin(STTOptions())
        var start = 0
        while start < pcm.count {
            let end = min(start + 640, pcm.count)
            session.append(AudioChunk(samples: Array(pcm[start..<end]), startMs: start / 16))
            start = end
        }
        let t = try await session.finish()
        let direct = try await giga.transcribe(url, options: FileSTTOptions()).map(\.text).joined(separator: " ")
        #expect(t.text == direct)
        #expect(t.provider == .gigaAM)
    }

    @Test func missingModelThrowsModelMissing() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("susu-empty-\(UUID().uuidString)")
        let stt = GigaAMSpeechToText(local: GigaAMLocal(modelDir: empty))
        await #expect(throws: STTError.modelMissing("gigaam-v3")) { _ = try await stt.begin(STTOptions()) }
    }

    @Test func chunkerSplitsLongAudioAtQuietPoint() {
        let n = 70 * 16_000
        var s = [Int16](repeating: 3000, count: n)
        // A quiet gap near 28 s and near 57 s.
        for i in (28 * 16_000)..<(28 * 16_000 + 3_200) { s[i] = 0 }
        for i in (57 * 16_000)..<(57 * 16_000 + 3_200) { s[i] = 0 }
        let r = GigaAMChunker.ranges(count: n, samples: s)
        #expect(r.first!.lowerBound == 0 && r.last!.upperBound == n)
        for (a, b) in zip(r, r.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
        #expect(r.allSatisfy { $0.count <= GigaAMChunker.maxSamples })
        #expect(abs(r[0].upperBound - (28 * 16_000 + 1_600)) < 2_000)
    }

    /// Writes runs/susu-gigaam.json in the stage-2 format. Enabled with SUSU_GIGAAM_BENCH=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUSU_GIGAAM_BENCH"] != nil && GigaAMTestEnv.haveModelAndClips))
    func benchAllClips() async throws {
        let dir = GigaAMTestEnv.testset
        let giga = GigaAMLocal(modelDir: try #require(GigaAMTestEnv.modelDir))
        try giga.engine.warmUp()
        _ = try await giga.transcribe(samples: [Int16](repeating: 0, count: 16_000))   // first-run warm-up, not measured
        let clips = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("clips/clips.json"))) as! [[String: Any]]
        var run: [String: [String: Any]] = [:]
        var secs: [Double] = []
        for c in clips {
            let id = c["id"] as! String
            let pcm = try WAVFile.readSamples(dir.appendingPathComponent("clips/\(id).wav"))
            let t0 = Date()
            let segs = try await giga.transcribe(samples: pcm)
            let sec = Date().timeIntervalSince(t0)
            run[id] = ["text": segs.map(\.text).joined(separator: " "), "sec": (sec * 1000).rounded() / 1000]
            secs.append(sec)
        }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("runs"), withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("runs/susu-gigaam.json")
        try JSONSerialization.data(withJSONObject: run, options: [.prettyPrinted, .sortedKeys]).write(to: out)
        secs.sort()
        print("GIGAAM BENCH clips=\(secs.count) median_sec=\(secs[secs.count / 2]) -> \(out.path)")
        #expect(run.count == clips.count)
    }
}
