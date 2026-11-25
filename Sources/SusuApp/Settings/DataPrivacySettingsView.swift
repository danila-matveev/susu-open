// «Данные и приватность»: audio retention, space used, data folder, who gets what (live), export, erase, Wispr import.
import AppKit
import SwiftUI
import SusuCore

extension Notification.Name {
    /// Posted by «Импорт…»; the import screen (Import task) observes it and opens its dialog.
    public static let susuOpenWisprImport = Notification.Name("susu.openWisprImport")
}

public struct DataPrivacySettingsView: View {
    public init() {}
    public var body: some View { LiveHost { live, model in DataPrivacyContent(live: live, model: model) } }
}

private enum Phase { case idle, working, done, failed }

private struct DataPrivacyContent: View {
    @ObservedObject var live: SettingsLive
    @ObservedObject var model: ShellModel
    @State private var usage = DataUsage(dictationAudio: 0, callAudio: 0, database: 0, models: 0)
    @State private var export = Phase.idle
    @State private var exportedURL: URL?
    @State private var erase = Phase.idle
    @State private var confirming = false

    private var services: AppServices { model.services }

    private var retention: Binding<Int> {
        live.binding(\.audioRetentionDays)
    }

    var body: some View {
        SettingsPage(section: .data) {
            SGroup(title: "d.store", first: true) {
                SRow("d.keep", detail: "d.keep.d") {
                    SSeg(selection: retention, items: [
                        SSegItem(value: 14, key: "d.14"), SSegItem(value: 90, key: "d.90"),
                        SSegItem(value: AudioRetention.forever, key: "d.inf"),
                    ])
                }
            }
            SGroup(title: "d.space") {
                let rows: [(String, Int64)] = [("d.s1", usage.dictationAudio), ("d.s2", usage.callAudio),
                                               ("d.s3", usage.database), ("d.s4", usage.models)]
                let top = max(1, rows.map(\.1).max() ?? 1)
                ForEach(rows, id: \.0) { r in
                    SFree {
                        HStack(spacing: 16) {
                            T(r.0).susuType(.body).foregroundStyle(Palette.ink).frame(width: 150, alignment: .leading)
                            SMeter(value: Double(r.1) / Double(top))
                            Text(verbatim: bytes(r.1)).susuType(.small).monospacedDigit().foregroundStyle(Palette.ink2)
                                .frame(width: 80, alignment: .trailing)
                        }
                    }
                }
                SRow("d.folder", detail: nil) {
                    HStack(spacing: 12) {
                        Text(verbatim: abbreviated(services.dataDirectory.path)).susuType(.small)
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.ink2)
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .trailing)
                        SBtn("show.finder") { NSWorkspace.shared.activateFileViewerSelecting([services.dataDirectory]) }
                    }
                }
            }
            privacyTable
            SGroup(title: "d.mine") {
                SRow("d.exp", detail: "d.exp.d") { exportControl }
                SRow("d.del", detail: "d.del.d") { eraseControl }
                SRow("d.imp", detail: "d.imp.d") {
                    SBtn("d.imp.b") { NotificationCenter.default.post(name: .susuOpenWisprImport, object: nil) }
                }
            }
        }
        .task { await refreshUsage() }
        .sheet(isPresented: $confirming) {
            EraseConfirm(language: model.language) { confirming = false } confirm: { confirming = false; runErase() }
        }
    }

    // MARK: Privacy table

    private var modeKey: String {
        switch live.value.preferences.workMode { case .cloud: "mc.cloud"; case .ownKeys: "mc.keys"; case .macOnly: "mc.mac" }
    }

    private var privacyTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                T("d.priv").susuType(.title2).foregroundStyle(Palette.ink)
                Spacer()
                (T("d.now") + Text(verbatim: " ") + T(modeKey)).susuType(.small).foregroundStyle(Palette.ink3)
            }
            .padding(.top, 32).padding(.bottom, 12)
            GroupedRows {
                HStack(spacing: 16) {
                    T("d.what").frame(maxWidth: .infinity, alignment: .leading)
                    T("d.where").frame(width: 250, alignment: .leading)
                }
                .susuType(.caption).foregroundStyle(Palette.ink3).padding(.vertical, 12).settingsRowLine()
                ForEach(PrivacyMap.rows(settings: live.value, registry: services.registry)) { row in
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            T(row.id).susuType(.body).foregroundStyle(Palette.ink)
                            T(row.id + "w").susuType(.small).foregroundStyle(Palette.ink3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        destination(row.destination).frame(width: 250, alignment: .leading)
                    }
                    .padding(.vertical, 12).settingsRowLine()
                }
                SNote("d.note")
            }
        }
        .padding(.horizontal, 36)
    }

    @ViewBuilder private func destination(_ d: PrivacyRow.Destination) -> some View {
        switch d {
        case .viaCloud: T("v.via").susuType(.small).foregroundStyle(Palette.ink2)
        case .provider(let name): (T("v.prov") + Text(verbatim: " \(name)")).susuType(.small).foregroundStyle(Palette.ink2)
        case .nowhere: SBadge(text: T("v.none"), kind: .ok)
        case .onMac: SBadge(text: T("v.mac"), kind: .ok)
        case .mixedSpeechCloud: T("v.mix").susuType(.small).foregroundStyle(Palette.ink2)
        case .skillService: T("v.svc").susuType(.small).foregroundStyle(Palette.ink2)
        }
    }

    // MARK: Export and erase

    @ViewBuilder private var exportControl: some View {
        switch export {
        case .idle, .failed:
            HStack(spacing: 12) {
                if export == .failed { T("d.exp.fail").susuType(.small).foregroundStyle(Palette.error) }
                SBtn("d.exp.b") { runExport() }
            }
        case .working: Button { } label: { T("d.exp.ing") }.buttonStyle(.susu(.neutral)).disabled(true)
        case .done:
            HStack(spacing: 12) {
                SBadge(text: T("d.exp.done"), kind: .ok)
                if let url = exportedURL { SBtn("show.finder", size: .small) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            }
        }
    }

    @ViewBuilder private var eraseControl: some View {
        switch erase {
        case .idle, .failed: SBtn("d.del.b", .destructive) { confirming = true }
        case .working: Button { } label: { T("d.del.ing") }.buttonStyle(.susu(.neutral)).disabled(true)
        case .done: SBadge(text: T("d.del.done"), kind: .ok)
        }
    }

    private func runExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
        panel.nameFieldStringValue = "Susu-export-\(day).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        export = .working
        let exporter = DataExporter(directory: services.dataDirectory, database: services.database)
        Task {
            let ok = await Task.detached { (try? exporter.export(to: url)) != nil }.value
            exportedURL = ok ? url : nil
            export = ok ? .done : .failed
        }
    }

    private func runErase() {
        erase = .working
        Task {
            do {
                try await DataEraser.eraseAll(in: services.dataDirectory, database: services.database, settings: services.settings)
                erase = .done
            } catch { erase = .failed }
            await refreshUsage()
        }
    }

    private func refreshUsage() async {
        let dir = services.dataDirectory
        usage = await Task.detached { DataUsage.measure(in: dir) }.value
    }

    private func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return n == 0 ? tr("d.zero", model.language) : f.string(fromByteCount: n)
    }

    private func abbreviated(_ path: String) -> String {
        path.hasPrefix(NSHomeDirectory()) ? "~" + path.dropFirst(NSHomeDirectory().count) : path
    }
}

/// «Удалить всё?»: the button unlocks when the word is typed.
private struct EraseConfirm: View {
    let language: InterfaceLanguage
    let cancel: () -> Void
    let confirm: () -> Void
    @State private var typed = ""

    private var matches: Bool {
        let t = typed.trimmingCharacters(in: .whitespaces).lowercased()
        return t == tr("dl.word", language).lowercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            T("dl.t").susuType(.title).foregroundStyle(Palette.ink)
            T("dl.p").susuType(.body).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            SField(text: $typed, placeholder: tr("dl.word", language)) { if matches { confirm() } }
            HStack {
                Spacer()
                SBtn("cancel", action: cancel)
                Button(action: confirm) { T("dl.go") }.buttonStyle(.susu(.primary)).disabled(!matches)
            }
        }
        .padding(28).frame(width: 440)
        .background(Palette.bgCard)
    }
}

#Preview("Data, light") {
    let model = ShellModel(services: .temporary())
    return DataPrivacySettingsView().shellRoot(model).frame(width: 700, height: 900).background(Palette.bgCard).preferredColorScheme(.light)
}
