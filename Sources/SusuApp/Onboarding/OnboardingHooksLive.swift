// Real implementations of the wizard hooks: GigaAM download and Wispr import (M4).
import Foundation
import SusuCore

extension OnboardingHooks {
    static func live(services s: AppServices) -> OnboardingHooks {
        var h = OnboardingHooks()
        let models = ModelDownloader(modelsRoot: s.dataDirectory.appendingPathComponent("models"))
        h.downloadGigaAM = { progress in
            let d = models.downloadGigaAM()
            let relay = Task { for await p in d.progress { progress(p) } }
            defer { relay.cancel() }
            _ = try await d.task.value
        }
        @Sendable func importer() throws -> WisprImporter {
            WisprImporter(database: s.database, dataDirectory: s.dataDirectory, wisprFolder: try WisprImporter.defaultWisprFolder())
        }
        h.wisprDryRun = {
            try? await s.styles.seedDefaultsIfEmpty()   // import maps Wispr styles onto the default ones
            guard let r = try? await importer().dryRun() else { return nil }
            func n(_ step: String) -> Int { r.step(step)?.total ?? 0 }
            let free = (try? s.dataDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage) ?? 0
            let audio = n("Audio")
            // ponytail: ~40 KB per dictation as m4a; measure the real size if the estimate misleads.
            return WisprPreview(dictations: n("History"), audioFiles: audio, vocabulary: n("Dictionary"),
                                styleGroups: n("Styles"), calls: n("Meetings"), notes: n("Notes"),
                                neededBytes: Int64(audio) * 40_000, freeBytes: free)
        }
        h.wisprImport = { includeAudio, progress in
            try? await s.styles.seedDefaultsIfEmpty()
            _ = try await importer().run(includeAudio: includeAudio) { p in
                progress(p.total > 0 ? Double(p.done) / Double(p.total) : 0)
            }
        }
        return h
    }
}
