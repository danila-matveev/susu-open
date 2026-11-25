// «Импорт» in the Dictionary: words, replacements and snippets from another dictation app (BUILD-PLAN T4.6).
import AppKit
import SwiftUI
import SusuCore
import UniformTypeIdentifiers

struct ImportSheet: View {
    let services: AppServices
    let lang: InterfaceLanguage
    let close: () -> Void
    /// Called after a finished import; the caller closes the sheet and reloads the list.
    let finish: (DictionaryImportResult) -> Void
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        dt("import.title").susuType(.title).tracking(-0.2).foregroundStyle(Palette.ink)
        dt("import.sub").susuType(.body).foregroundStyle(Palette.ink2)
        VStack(alignment: .leading, spacing: Space.s4) {
            row(title: "import.file", detail: "import.file.d", action: "import.choose") { importFile(.file) }
            row(title: "import.voiceink", detail: "import.voiceink.d", action: "import.choose") { importFile(.voiceink) }
            row(title: "import.superwhisper", detail: "import.superwhisper.d", action: "import.run") { importSuperwhisper() }
        }
        if failed {
            dt("import.failed").susuType(.small).foregroundStyle(Palette.error)
        }
        HStack(spacing: Space.s2) {
            EscHint()
            Spacer(minLength: 0)
            Button(action: close) { dt("common.cancel") }
                .buttonStyle(.susu(.neutral)).keyboardShortcut(.cancelAction)
        }
        .padding(.top, 4)
    }

    private func row(title: LocalizedStringKey, detail: LocalizedStringKey, action: LocalizedStringKey,
                     run: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: 2) {
                dt(title).susuType(.body).foregroundStyle(Palette.ink)
                dt(detail).susuType(.small).foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 0)
            Button(action: run) { dt(action) }.buttonStyle(.susu(.neutral)).disabled(busy)
        }
    }

    private func importFile(_ source: DictionaryImportSource) {
        guard let url = Self.pickFile() else { return }
        start { importer in try await importer.importFile(url, source: source) }
    }

    private func importSuperwhisper() {
        guard let folder = DictionaryImporter.defaultSuperwhisperFolder() ?? Self.pickFolder() else { return }
        start { importer in try await importer.importSuperwhisper(folder: folder) }
    }

    private func start(_ work: @escaping @Sendable (DictionaryImporter) async throws -> DictionaryImportResult) {
        busy = true
        failed = false
        let importer = DictionaryImporter(database: services.database)
        Task {
            do {
                let result = try await work(importer)
                busy = false
                finish(result)
            } catch {
                busy = false
                failed = true
            }
        }
    }

    @MainActor private static func pickFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.text, .json, .commaSeparatedText, .tabSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asked only when Superwhisper's folder is not in one of its two usual places.
    @MainActor private static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
