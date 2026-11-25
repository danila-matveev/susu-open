// «Агент»: «Обо мне» facts (edit, delete), agent model (link to Models), default time zone, excluded apps.
import SwiftUI
import SusuCore

public struct AgentSettingsView: View {
    public init() {}
    public var body: some View { LiveHost { live, model in AgentContent(live: live, model: model) } }
}

private let timeZoneChoices: [(id: String, key: String)] = [
    ("America/Sao_Paulo", "tz.sp"), ("Europe/Moscow", "tz.msk"), ("Europe/Lisbon", "tz.lis"),
    ("Asia/Dubai", "tz.dxb"), ("America/New_York", "tz.ny"),
]

private struct AgentContent: View {
    @ObservedObject var live: SettingsLive
    @ObservedObject var model: ShellModel
    @State private var facts: [MemoryFact] = []
    @State private var editingID: String?
    @State private var editText = ""
    @State private var newFact = ""
    @FocusState private var editFocus: Bool

    private var store: MemoryFactSettingsStore { MemoryFactSettingsStore(database: model.services.database) }

    var body: some View {
        SettingsPage(section: .agent) {
            SGroup(title: "g.about", first: true) {
                if facts.isEmpty { SFree(padding: 14) { T("fa.empty").susuType(.body).foregroundStyle(Palette.ink3) } }
                ForEach(facts) { f in factRow(f) }
                SFree {
                    HStack(spacing: 12) {
                        SField(text: $newFact, placeholder: tr("fa.ph", model.language)) { addFact() }
                        Button { addFact() } label: { T("add") }.buttonStyle(.susu(.neutral))
                            .disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            SGroup(title: "ag.title") {
                SRow("ag.model", detail: nil) {
                    if live.value.preferences.workMode == .cloud {
                        T("ag.cloud").susuType(.body).foregroundStyle(Palette.ink2)
                    } else {
                        HStack(spacing: 12) {
                            Text(verbatim: agentSummary).susuType(.body).foregroundStyle(Palette.ink2)
                            SBtn("ag.goto", .plain) { model.settingsSection = .models }
                        }
                    }
                }
                SRow("ag.tz", detail: "ag.tz.d") {
                    SSelect(selection: live.binding(\.preferences.agentTimeZone), options: tzOptions,
                            width: 220, help: tr("ag.tz", model.language))
                }
            }
            SGroup(title: "ag.ex") {
                AppListEditor(bundleIDs: live.binding(\.preferences.contextExclusions), suggestions: SettingsAppCatalog.sensitiveApps)
            }
        }
        .task { await reload() }
    }

    private var agentSummary: String {
        guard let c = live.value.providers.agent else { return tr("p.off", model.language) }
        let name = model.services.registry.info(for: c.providerID)?.displayName ?? c.providerID.rawValue
        return c.model.isEmpty ? name : "\(name) · \(c.model)"
    }

    private var tzOptions: [SOption<String>] {
        var list = timeZoneChoices.map { c in SOption(c.id, verbatim: "\(tr(c.key, model.language)) (\(Self.offset(c.id)))") }
        let cur = live.value.preferences.agentTimeZone
        if !timeZoneChoices.contains(where: { $0.id == cur }) { list.append(SOption(cur, verbatim: "\(cur) (\(Self.offset(cur)))")) }
        return list
    }

    static func offset(_ id: String) -> String {
        guard let tz = TimeZone(identifier: id) else { return "GMT" }
        let m = tz.secondsFromGMT() / 60
        if m == 0 { return "GMT+0" }
        let sign = m < 0 ? "−" : "+"
        let h = abs(m) / 60, mm = abs(m) % 60
        return "GMT\(sign)\(h)" + (mm == 0 ? "" : ":" + String(format: "%02d", mm))
    }

    private func factRow(_ f: MemoryFact) -> some View {
        SFree {
            HStack(spacing: 12) {
                if editingID == f.id {
                    SField(text: $editText) { commitEdit(f) }.focused($editFocus)
                } else {
                    Button { editingID = f.id; editText = f.text; editFocus = true } label: {
                        Text(verbatim: f.text).susuType(.body).foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(tr("fa.edit", model.language))
                }
                IconButton("xmark", help: nil) {
                    Task { try? await store.delete(id: f.id); await reload() }
                }
            }
        }
    }

    private func commitEdit(_ f: MemoryFact) {
        let text = editText
        editingID = nil
        Task { try? await store.update(id: f.id, text: text); await reload() }
    }

    private func addFact() {
        let t = newFact
        newFact = ""
        Task { _ = try? await store.add(t); await reload() }
    }

    private func reload() async { facts = (try? await store.facts()) ?? [] }
}

#Preview("Agent, light") {
    let model = ShellModel(services: .temporary())
    return AgentSettingsView().shellRoot(model).frame(width: 700, height: 700).background(Palette.bgCard).preferredColorScheme(.light)
}
