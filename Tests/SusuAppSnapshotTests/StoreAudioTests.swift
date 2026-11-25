import Foundation
import Testing
@testable import SusuApp
@testable import SusuCore

/// A recording must survive a failed m4a conversion (mandate, section 8: keep the user's source material).
@Suite struct StoreAudioTests {
    @Test func brokenWavIsKeptNotDeleted() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("susu-store-audio-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let wav = root.appendingPathComponent("in.wav")
        let bytes = Data("not a wav file".utf8)
        try bytes.write(to: wav)

        let path = DictationService.storeAudio(wav: wav, id: "abc", date: Date(timeIntervalSince1970: 1_795_000_000),
                                               root: root.appendingPathComponent("audio"))

        let kept = try #require(path)
        #expect(kept.hasSuffix("/abc.wav"))
        let stored = root.appendingPathComponent(kept)
        #expect(try Data(contentsOf: stored) == bytes)
    }
}

/// A dictation the database refuses is not dropped: it lands in recovery/<id>.json.
@Suite struct HistoryRecoveryTests {
    private struct Boom: Error {}

    @Test func failedSaveWritesRecoveryCopy() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("susu-recovery-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        var d = Dictation(id: "d1", createdAt: Date(timeIntervalSince1970: 1_795_000_000), durationMs: 1200, mode: .hold)
        d.finalText = "важный текст"
        d.audioPath = "audio/2026-11/d1.m4a"

        await DictationController.persist(d, save: { _ in throw Boom() },
                                          onFailed: { dictation, _ in DictationService.writeRecovery(dictation, root: root) })

        let back = try JSONDecoder().decode(Dictation.self, from: Data(contentsOf: root.appendingPathComponent("d1.json")))
        #expect(back.finalText == "важный текст")
        #expect(back.audioPath == "audio/2026-11/d1.m4a")
    }

    @Test func successfulSaveWritesNothing() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("susu-recovery-\(UUID().uuidString)")
        let d = Dictation(id: "d2", createdAt: Date(), durationMs: 1, mode: .hold)
        await DictationController.persist(d, save: { _ in }, onFailed: { dictation, _ in DictationService.writeRecovery(dictation, root: root) })
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
