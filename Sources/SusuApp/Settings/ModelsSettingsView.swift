// «Модели» (spec 4.3): one table of jobs. Per job: provider, model, key (Keychain, one per provider), «Проверить»,
// fallback provider. Every edit is written to settings at once; the next dictation or call uses it.
import SwiftUI
import SusuCore

enum ModelJob: String, CaseIterable, Identifiable {
    case dictation, dictationFallback, editor, callsByLanguage, callsMixedSpeech, callSummary, agent
    var id: String { rawValue }
    var titleKey: String { "j.\(rawValue)" }
    var detailKey: String { "j.\(rawValue).d" }
    /// Speech-to-text jobs offer recognition providers, the others offer chat providers.
    var isSpeech: Bool { self == .dictation || self == .dictationFallback || self == .callsByLanguage || self == .callsMixedSpeech }
    var canBeOff: Bool { self != .dictation }
    /// The dictation row has the next row as its fallback, and that row has none.
    var hasFallbackField: Bool { self != .dictation && self != .dictationFallback }

    func choice(_ s: SusuCore.Settings) -> ProviderChoice? {
        switch self {
        case .dictation: s.providers.dictation
        case .dictationFallback: s.providers.dictationFallback
        case .editor: s.providers.editor
        case .callsByLanguage: s.providers.callsByLanguage
        case .callsMixedSpeech: s.providers.callsMixedSpeech
        case .callSummary: s.providers.callSummary
        case .agent: s.providers.agent
        }
    }

    func setChoice(_ c: ProviderChoice?, _ s: inout SusuCore.Settings) {
        switch self {
        case .dictation: s.providers.dictation = c
        case .dictationFallback: s.providers.dictationFallback = c
        case .editor: s.providers.editor = c
        case .callsByLanguage: s.providers.callsByLanguage = c
        case .callsMixedSpeech: s.providers.callsMixedSpeech = c
        case .callSummary: s.providers.callSummary = c
        case .agent: s.providers.agent = c
        }
    }
}

enum ModelsLogic {
    static let off = "off"

    /// Providers a job can use, as tags (`off` for none).
    static func providerTags(for job: ModelJob, registry: ProviderRegistry) -> [String] {
        var tags: [String] = []
        if job.isSpeech {
            tags = [ProviderID.groq.rawValue, "openai", ProviderID.gigaAM.rawValue, "custom"]
        } else {
            tags = registry.providers.map(\.id.rawValue)
        }
        if job.canBeOff { tags.append(off) }
        return tags
    }

    /// A sensible model for a freshly picked provider.
    static func defaultModel(provider: ProviderID, speech: Bool, registry: ProviderRegistry) -> String {
        if provider == .gigaAM { return "gigaam-v3" }
        let prices = registry.info(for: provider)?.prices ?? []
        return (speech ? prices.first { $0.audioPerHour != nil } : prices.first { $0.inputPerMTok != nil })?.model ?? ""
    }

    static func suggestions(provider: ProviderID, speech: Bool, registry: ProviderRegistry) -> [String] {
        (registry.info(for: provider)?.prices ?? []).filter { speech ? $0.audioPerHour != nil : $0.inputPerMTok != nil }.map(\.model)
    }

    static func newChoice(provider: ProviderID, speech: Bool, previous: ProviderChoice?, registry: ProviderRegistry) -> ProviderChoice {
        let address: String? = (provider == "custom") ? (previous?.providerID == provider ? previous?.baseURL : nil) : nil
        return ProviderChoice(providerID: provider, model: defaultModel(provider: provider, speech: speech, registry: registry), baseURL: address)
    }
}

/// Debounced writer of one provider's key into the Keychain.
@MainActor
final class KeyEditor: ObservableObject {
    @Published var text: String
    /// Why the last save into the Keychain failed; nil when it went through.
    @Published var saveError: String?
    let provider: ProviderID
    private let secrets: SecretStore
    private var saveTask: Task<Void, Never>?

    init(provider: ProviderID, secrets: SecretStore) {
        self.provider = provider
        self.secrets = secrets
        text = (try? secrets.get(provider)) ?? ""
    }

    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    func scheduleSave(after delay: UInt64 = 600_000_000) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        do {
            if trimmed.isEmpty { try secrets.delete(provider) } else { try secrets.set(trimmed, for: provider) }
            saveError = nil
        } catch {
            saveError = "Keychain: \(error)"
        }
    }
}

/// Plain holder so editors can be created lazily during rendering.
@MainActor final class EditorCache { var items: [String: KeyEditor] = [:] }

public struct ModelsSettingsView: View {
    public init() {}
    public var body: some View { LiveHost { live, model in ModelsContent(live: live, model: model) } }
}

private struct ModelsContent: View {
    @ObservedObject var live: SettingsLive
    @ObservedObject var model: ShellModel
    @State private var open: ModelJob? = .dictation
    @State private var editors = EditorCache()
    @State private var results: [String: KeyCheckStatus?] = [:]  // nil value = checking
    @State private var showKey = false
    @State private var hasKey: Set<String> = []

    private var registry: ProviderRegistry { model.services.registry }

    var body: some View {
        SettingsPage(section: .models) {
            SGroup(first: true) {
                SNote(live.value.preferences.workMode == .macOnly ? "mo.mac" : (live.value.preferences.workMode == .cloud ? "mo.cloud" : "mo.keys"))
            }
            SGroup(title: "mo.jobs") {
                ForEach(ModelJob.allCases) { job in
                    VStack(spacing: 0) {
                        jobRow(job)
                        if open == job { panel(job) }
                    }
                }
            }
        }
        .onAppear(perform: refreshKeys)
    }

    // MARK: Rows

    private func providerName(_ id: ProviderID) -> String {
        if id == .gigaAM { return tr("p.giga", model.language) }
        if id == "custom" { return tr("p.custom", model.language) }
        return registry.info(for: id)?.displayName ?? id.rawValue
    }

    private func summary(_ c: ProviderChoice?) -> Text {
        guard let c else { return T("p.off") }
        return Text(verbatim: c.model.isEmpty ? providerName(c.providerID) : "\(providerName(c.providerID)) · \(c.model)")
    }

    private func needsKey(_ id: ProviderID) -> Bool { (registry.info(for: id)?.needsKey ?? false) || id == "custom" }

    private func jobRow(_ job: ModelJob) -> some View {
        let c = job.choice(live.value)
        let isOpen = open == job
        return HStack(spacing: Space.s6) {
            VStack(alignment: .leading, spacing: 2) {
                T(job.titleKey).susuType(.bodyStrong).foregroundStyle(Palette.ink)
                summary(c).susuType(.body).foregroundStyle(Palette.ink2)
            }
            Spacer(minLength: 0)
            badge(for: c)
            Button {
                withAnimation(Motion.standard) { open = isOpen ? nil : job }
                if !isOpen, let c, needsKey(c.providerID) { _ = editor(c.providerID) }
            } label: { isOpen ? T("done") : T("change") }
            .buttonStyle(.susu(.neutral))
        }
        .padding(.vertical, Space.s4).frame(minHeight: 68)
        .settingsRowLine()
    }

    private func badge(for c: ProviderChoice?) -> AnyView {
        guard let c, needsKey(c.providerID), live.value.preferences.workMode != .macOnly else { return AnyView(EmptyView()) }
        let id = c.providerID.rawValue
        if let r = results[id] {
            guard let r else { return AnyView(SBadge(text: T("checking"), kind: .busy)) }
            switch r {
            case .works: return AnyView(SBadge(text: T("works"), kind: .ok))
            case .wrongKey: return AnyView(SBadge(text: T("bad.key"), kind: .error))
            case .noMoney: return AnyView(SBadge(text: T("no.money"), kind: .error))
            case .noNetwork: return AnyView(SBadge(text: T("offline"), kind: .error))
            case .other: return AnyView(SBadge(text: T("check.failed"), kind: .error))
            }
        }
        if c.providerID != "custom", !hasKey.contains(id) { return AnyView(SBadge(text: T("no.key"), kind: .error)) }
        return AnyView(EmptyView())
    }

    // MARK: Panel

    private func editor(_ id: ProviderID) -> KeyEditor {
        if let e = editors.items[id.rawValue] { return e }
        let e = KeyEditor(provider: id, secrets: model.services.secrets)
        editors.items[id.rawValue] = e
        return e
    }

    private func refreshKeys() {
        hasKey = Set(registry.providers.map(\.id).filter { (try? model.services.secrets.get($0)) != nil }.map(\.rawValue))
    }

    private func panel(_ job: ModelJob) -> some View {
        let c = job.choice(live.value)
        let tags = ModelsLogic.providerTags(for: job, registry: registry)
        let tag = c?.providerID.rawValue ?? ModelsLogic.off
        return VStack(alignment: .leading, spacing: 12) {
            formRow("f.prov") {
                SSelect(selection: Binding(get: { tag }, set: { pick($0, job) }),
                        options: tags.map { t in t == ModelsLogic.off ? SOption(t, key: "p.off") : SOption(t, verbatim: providerName(ProviderID(t))) },
                        width: nil, help: tr("f.prov", model.language))
            }
            if let c {
                formRow("f.model") {
                    HStack(spacing: 8) {
                        SField(text: Binding(get: { c.model }, set: { setModel($0, job) }), placeholder: tr("f.model", model.language), mono: true)
                        let list = ModelsLogic.suggestions(provider: c.providerID, speech: job.isSpeech, registry: registry)
                        if !list.isEmpty {
                            Menu {
                                ForEach(list, id: \.self) { m in Button(m) { setModel(m, job) } }
                            } label: {
                                Image(systemName: "list.bullet").font(.system(size: 14)).foregroundStyle(Palette.ink2)
                                    .frame(width: Metrics.control, height: Metrics.control)
                                    .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Palette.lineStrong))
                            }
                            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        }
                    }
                }
                if c.providerID == "custom" {
                    formRow("f.addr") {
                        SField(text: Binding(get: { c.baseURL ?? "" }, set: { setAddress($0, job) }),
                               placeholder: "http://localhost:1234/v1", mono: true)
                    }
                }
                if needsKey(c.providerID), live.value.preferences.workMode != .macOnly { keyRow(c) }
            }
            if job.hasFallbackField { fallbackRow(job) }
        }
        .padding(.top, 4).padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formRow<C: View>(_ key: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 16) {
            T(key).susuType(.small).foregroundStyle(Palette.ink2).frame(width: 110, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func keyRow(_ c: ProviderChoice) -> some View {
        let ed = editor(c.providerID)
        return VStack(alignment: .leading, spacing: 8) {
            formRow("f.key") {
                HStack(spacing: 8) {
                    KeyFieldView(editor: ed, show: showKey, placeholder: tr("f.keyph", model.language)) { refreshKeys() }
                    IconButton(showKey ? "eye.slash" : "eye") { showKey.toggle() }
                    SBtn("check") { runCheck(c, ed) }
                }
            }
            if let r = results[c.providerID.rawValue] {
                HStack(spacing: 16) {
                    Color.clear.frame(width: 110, height: 1)
                    resultLine(r).susuType(.small)
                }
            }
        }
    }

    @ViewBuilder private func resultLine(_ r: KeyCheckStatus?) -> some View {
        switch r {
        case nil: T("checking").foregroundStyle(Palette.ink2)
        case .works?: T("works").foregroundStyle(Palette.ok)
        case .wrongKey?: T("bad.key.d").foregroundStyle(Palette.error)
        case .noMoney?: T("no.money.d").foregroundStyle(Palette.error)
        case .noNetwork?: T("offline.d").foregroundStyle(Palette.error)
        case .other(let why)?: (T("check.failed") + Text(verbatim: ": \(why)")).foregroundStyle(Palette.error)
        }
    }

    private func fallbackRow(_ job: ModelJob) -> some View {
        let current = live.value.preferences.jobFallbacks[job.rawValue]
        let tags = ["none"] + ModelsLogic.providerTags(for: job, registry: registry)
            .filter { $0 != ModelsLogic.off && $0 != "custom" && $0 != ProviderID.gigaAM.rawValue && $0 != "ollama" }
        return formRow("f.fb") {
            SSelect(selection: Binding(get: { current?.providerID.rawValue ?? "none" }, set: { t in
                let speech = job.isSpeech
                live.set { s in
                    if t == "none" { s.preferences.jobFallbacks[job.rawValue] = nil }
                    else { s.preferences.jobFallbacks[job.rawValue] = ModelsLogic.newChoice(provider: ProviderID(t), speech: speech, previous: nil, registry: registry) }
                }
            }), options: tags.map { $0 == "none" ? SOption($0, key: "p.none") : SOption($0, verbatim: providerName(ProviderID($0))) },
                    width: nil, help: tr("f.fb", model.language))
        }
    }

    // MARK: Actions

    private func pick(_ tag: String, _ job: ModelJob) {
        let speech = job.isSpeech
        live.set { s in
            if tag == ModelsLogic.off { job.setChoice(nil, &s) }
            else {
                let prev = job.choice(s)
                job.setChoice(ModelsLogic.newChoice(provider: ProviderID(tag), speech: speech, previous: prev, registry: registry), &s)
            }
        }
        if tag != ModelsLogic.off, needsKey(ProviderID(tag)) { _ = editor(ProviderID(tag)) }
    }

    private func setModel(_ m: String, _ job: ModelJob) {
        live.set { s in
            guard var c = job.choice(s) else { return }
            c.model = m
            job.setChoice(c, &s)
        }
    }

    private func setAddress(_ a: String, _ job: ModelJob) {
        live.set { s in
            guard var c = job.choice(s) else { return }
            c.baseURL = a.isEmpty ? nil : a
            job.setChoice(c, &s)
        }
    }

    private func runCheck(_ c: ProviderChoice, _ ed: KeyEditor) {
        ed.saveNow()
        refreshKeys()
        let id = c.providerID
        let key = ed.trimmed
        let address = c.baseURL
        guard !key.isEmpty else { results[id.rawValue] = .some(.wrongKey); return }
        results[id.rawValue] = .some(nil)
        let checker = KeyChecker(registry: registry)
        Task {
            let r = await checker.check(provider: id, key: key, baseURL: address)
            results[id.rawValue] = .some(r)
        }
    }
}

/// Key input bound to a KeyEditor (saves 0.6 s after typing stops).
private struct KeyFieldView: View {
    @ObservedObject var editor: KeyEditor
    let show: Bool
    let placeholder: String
    let onSaved: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SField(text: $editor.text, placeholder: placeholder, secure: !show, mono: true) { editor.saveNow(); onSaved() }
                .onChange(of: editor.text) { _, _ in editor.scheduleSave() }
            if let failure = editor.saveError { Text(verbatim: failure).susuType(.small).foregroundStyle(Palette.error) }
        }
    }
}

#Preview("Models, light") {
    let model = ShellModel(services: .temporary())
    return ModelsSettingsView().shellRoot(model).frame(width: 700, height: 700).background(Palette.bgCard).preferredColorScheme(.light)
}
