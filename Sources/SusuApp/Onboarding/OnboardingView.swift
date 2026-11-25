// The wizard sheet (docs/design/prototype/onboarding.html): step dots, title, body, «Пропустить» + one primary action.
import SwiftUI
import SusuCore

enum ONS {
    static func string(_ key: String, _ lang: InterfaceLanguage, _ args: CVarArg...) -> String {
        let f = L10n.bundle(for: lang).localizedString(forKey: key, value: nil, table: "Onboarding")
        return args.isEmpty ? f : String(format: f, locale: L10n.locale(for: lang), arguments: args)
    }
    static func bytes(_ n: Int64, _ lang: InterfaceLanguage) -> String {
        let ru = L10n.locale(for: lang).identifier.hasPrefix("ru")
        let gb = Double(n) / 1_000_000_000
        if gb >= 1 { return gb.formatted(.number.precision(.fractionLength(1)).locale(L10n.locale(for: lang))) + (ru ? " ГБ" : " GB") }
        return Int((Double(n) / 1_000_000).rounded()).formatted() + (ru ? " МБ" : " MB")
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @EnvironmentObject private var shell: ShellModel
    private var lang: InterfaceLanguage { shell.language }
    private func s(_ k: String, _ a: CVarArg...) -> String { ONS.string(k, lang, a.isEmpty ? [] : a) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            top
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    titleBlock
                    stepBody
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            footer
        }
        .padding(40)
        .padding(.top, 8)
        .frame(width: 560, height: 720)
        .background(Palette.bgCard)
        .ignoresSafeArea()
        .susuAnimation(Motion.standard, value: model.step)
    }

    // MARK: Chrome

    private var top: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<model.steps.count, id: \.self) { i in
                    Capsule().fill(model.step == .finish || i == model.stepNumber - 1 ? Palette.accent : Palette.lineStrong)
                        .frame(width: model.step == .finish || i == model.stepNumber - 1 ? 20 : 6, height: 6)
                }
            }
            .susuAnimation(Motion.slow, value: model.step)
            Spacer()
            Text(model.step == .finish ? s("ob.allDone") : s("ob.step", model.stepNumber, model.steps.count))
                .susuType(.small).foregroundStyle(Palette.ink3)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                if model.step == .finish {
                    Image(systemName: "checkmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ok)
                        .frame(width: 40, height: 40).background(Palette.okSoft, in: Circle())
                }
                Text(verbatim: titleText).susuType(.display).tracking(-0.3).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let t = subtitle {
                Text(verbatim: t).susuType(.body).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var titleText: String {
        switch model.step {
        case .permissions: s(model.mic == .denied ? "ob.perm.titleDenied" : "ob.perm.title")
        case .how: s("ob.how.title")
        case .trial: s("ob.try.title")
        case .wispr:
            switch model.wispr {
            case .found, .loading, .failed: s("ob.wispr.title")
            case .dry: s("ob.wispr.dryTitle")
            case .noSpace: s("ob.wispr.noSpaceTitle")
            case .importing: s("ob.wispr.progressTitle")
            case .done: s("ob.wispr.doneTitle")
            }
        case .finish: s("ob.fin.title", model.dictationKeyName(lang))
        }
    }

    private var subtitle: String? {
        switch model.step {
        case .permissions: s("ob.perm.text")
        case .how: s("ob.how.text")
        case .trial: s("ob.try.text")
        case .wispr:
            switch model.wispr {
            case .found, .loading, .failed: s("ob.wispr.text")
            case .dry: s("ob.wispr.dryText")
            case .noSpace(let p): s("ob.wispr.noSpaceText", ONS.bytes(p.neededBytes, lang), ONS.bytes(p.freeBytes, lang))
            case .importing, .done: nil
            }
        case .finish: s("ob.fin.text")
        }
    }

    @ViewBuilder private var stepBody: some View {
        switch model.step {
        case .permissions: permissions
        case .how: how
        case .trial: trial
        case .wispr: wispr
        case .finish: finish
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            footerContent
        }
        .padding(.top, 8)
    }

    @ViewBuilder private var footerContent: some View {
        switch model.step {
        case .permissions:
            skipButton
            Spacer()
            if model.mic == .denied { primary("ob.perm.btnSettings") { model.openMicSettings() } }
            else if model.mic == .notDetermined { primary("ob.perm.btnMic") { model.askMic() } }
            else if !model.axTrusted && !model.axRequested { primary("ob.perm.btnAx") { model.askAccessibility() } }
            else { primary("ob.next", enabled: model.axTrusted) { model.advance() } }
        case .how:
            skipButton
            Spacer()
            primary("ob.next", enabled: model.choice != .cloud && !isDownloading) { model.advance() }
        case .trial:
            skipButton
            Spacer()
            primary("ob.next", enabled: model.trialDone) { model.advance() }
        case .wispr:
            wisprFooter
        case .finish:
            Text(verbatim: s("ob.fin.settingsHint")).susuType(.small).foregroundStyle(Palette.ink3)
            Spacer()
            primary("ob.fin.open") { model.finish(openHistory: true) }
        }
    }

    private var isDownloading: Bool { if case .downloading = model.mac { true } else { false } }

    private var skipButton: some View {
        Button { model.skip() } label: { Text(verbatim: s("ob.skip")) }.buttonStyle(.susu(.plain))
    }

    private func primary(_ key: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(verbatim: s(key)) }
            .buttonStyle(.susu(.primary, size: .large)).disabled(!enabled)
            .keyboardShortcut(.defaultAction)
    }

    // MARK: Step 1

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            WizList {
                permRow("mic", "ob.perm.mic", "ob.perm.micDesc") {
                    switch model.mic {
                    case .granted: badge(s("ob.perm.yes"), .ok)
                    case .denied: badge(s("ob.perm.denied"), .error)
                    case .notDetermined: badge(s("ob.perm.no"), .preparing)
                    }
                }
                Divider().overlay(Palette.line)
                permRow("hand.raised", "ob.perm.ax", "ob.perm.axDesc") {
                    if model.axTrusted { badge(s("ob.perm.axYes"), .ok) }
                    else if model.axRequested {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(verbatim: s("ob.perm.waiting")).susuType(.small).foregroundStyle(Palette.ink2) }
                    } else { badge(s("ob.perm.no"), .preparing) }
                }
            }
            if model.mic == .denied {
                HStack(alignment: .top, spacing: 0) {
                    (Text(verbatim: s("ob.perm.deniedLead") + " ").fontWeight(.semibold).foregroundStyle(Palette.error)
                        + Text(verbatim: s("ob.perm.deniedHow")).foregroundStyle(Palette.ink2))
                        .susuType(.small).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Palette.error, lineWidth: 1))
            }
            if model.axRequested || model.axTrusted {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 16) {
                        ForEach(Array(["ob.perm.s1", "ob.perm.s2", "ob.perm.s3"].enumerated()), id: \.offset) { i, k in
                            HStack(spacing: 8) {
                                Text("\(i + 1)").susuType(.caption).frame(width: 20, height: 20).background(Palette.bgFill, in: Circle())
                                Text(verbatim: s(k)).susuType(.small).foregroundStyle(Palette.ink2)
                            }
                        }
                    }
                    Text(verbatim: s(model.axTrusted ? "ob.perm.polled" : "ob.perm.poll")).susuType(.small).foregroundStyle(Palette.ink3)
                }
            }
        }
    }

    private func permRow<T: View>(_ icon: String, _ title: String, _ desc: String, @ViewBuilder status: () -> T) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Palette.accentInk).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: s(title)).susuType(.body).fontWeight(.medium).foregroundStyle(Palette.ink)
                Text(verbatim: s(desc)).susuType(.small).foregroundStyle(Palette.ink2)
            }
            Spacer(minLength: 8)
            status()
        }
        .padding(.vertical, 14)
    }

    private func badge(_ text: String, _ kind: StatusBadge.Kind) -> some View { WizBadge(text: text, kind: kind) }

    // MARK: Step 2

    private var how: some View {
        VStack(spacing: 12) {
            // Susu Cloud: the server does not exist yet, so the card is visible but cannot be chosen.
            OptionCard(selected: false, enabled: false, icon: "cloud", title: s("ob.how.cloud"), desc: s("ob.how.cloudDesc"),
                       tag: s("ob.how.soon")) {} content: {
                Text(verbatim: s("ob.how.cloudSoon")).susuType(.small).foregroundStyle(Palette.ink2)
            }
            OptionCard(selected: model.choice == .keys, enabled: true, icon: "key", title: s("ob.how.keys"), desc: s("ob.how.keysDesc"), tag: nil) {
                model.choice = .keys
            } content: {
                VStack(alignment: .leading, spacing: 12) {
                    keyRow(.groq, "Groq", $model.groqKey)
                    keyRow(.openRouter, "OpenRouter", $model.openRouterKey)
                    Text(verbatim: s("ob.how.keyNote")).susuType(.small).foregroundStyle(Palette.ink3)
                }
            }
            OptionCard(selected: model.choice == .mac, enabled: true, icon: "laptopcomputer", title: s("ob.how.mac"), desc: s("ob.how.macDesc"), tag: nil) {
                model.choice = .mac
            } content: { macContent }
        }
    }

    private func keyRow(_ p: ProviderID, _ label: String, _ text: Binding<String>) -> some View {
        let r = model.keyResults[p] ?? .none
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(verbatim: label).susuType(.label).frame(width: 84, alignment: .leading)
                SecureField("", text: text, prompt: Text(verbatim: s("ob.how.keyPh")).foregroundStyle(Palette.ink3))
                    .textFieldStyle(.plain).susuType(.body).padding(.horizontal, 12).frame(height: Metrics.control)
                    .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .strokeBorder(r == .wrong || r == .empty ? Palette.error : Palette.lineStrong, lineWidth: 1))
                    .onChange(of: text.wrappedValue) { _, _ in model.keyResults[p] = OnboardingModel.KeyResult.none }
                Button { model.checkKey(p) } label: { Text(verbatim: s("ob.check")) }
                    .buttonStyle(.susu(.neutral)).disabled(r == .checking)
            }
            HStack(spacing: 8) {
                Spacer().frame(width: 96)
                switch r {
                case .none: EmptyView()
                case .checking: ProgressView().controlSize(.small); Text(verbatim: s("ob.checking")).susuType(.small).foregroundStyle(Palette.ink2)
                case .works: Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ok)
                    Text(verbatim: s("ob.works")).susuType(.small).foregroundStyle(Palette.ok)
                case .wrong: err("ob.how.bad")
                case .empty: err("ob.how.empty")
                case .offline: err("ob.how.offline")
                case .noMoney: err("ob.how.noMoney")
                case .other(let m): Text(verbatim: s("ob.how.other", m)).susuType(.small).foregroundStyle(Palette.error)
                }
            }
        }
    }

    private func err(_ k: String) -> some View { Text(verbatim: s(k)).susuType(.small).foregroundStyle(Palette.error) }

    @ViewBuilder private var macContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.mac {
            case .idle, .failed:
                if model.mac == .failed { err("ob.how.downloadFailed") }
                else { Text(verbatim: s("ob.how.macText")).susuType(.small).foregroundStyle(Palette.ink2) }
                if model.hooks.downloadGigaAM == nil {
                    Text(verbatim: s("ob.how.downloadSoon")).susuType(.small).foregroundStyle(Palette.ink3)
                } else {
                    Button { model.startDownload() } label: {
                        Label { Text(verbatim: model.mac == .failed ? s("ob.retry") : s("ob.how.download")) } icon: { Image(systemName: "arrow.down.circle") }
                    }.buttonStyle(.susu(.neutral))
                }
            case .downloading(let p):
                ProgressView(value: p).tint(Palette.accent)
                HStack {
                    Text(verbatim: s("ob.how.downloading", Int(p * 230))).susuType(.small).foregroundStyle(Palette.ink2).monospacedDigit()
                    Button { model.cancelDownload() } label: { Text(verbatim: s("ob.cancel")) }.buttonStyle(.susu(.quiet, size: .small))
                }
            case .done:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ok)
                    Text(verbatim: s("ob.how.downloaded")).susuType(.small).foregroundStyle(Palette.ink)
                }
            }
        }
    }

    // MARK: Step 3

    private var trial: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Text(verbatim: s("ob.try.hold")).susuType(.body).foregroundStyle(Palette.ink2)
                Text(verbatim: model.dictationKeyName(lang)).susuType(.label).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 8).frame(minWidth: 24, minHeight: 24)
                    .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)).susuShadow(.card, radius: Radius.sm)
                Text(verbatim: s("ob.try.andSay")).susuType(.body).foregroundStyle(Palette.ink2)
            }
            TrialField(text: $model.trialText, placeholder: s("ob.try.placeholder"), label: s("ob.try.fieldA"))
            if model.trialDone {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ok)
                    Text(verbatim: s("ob.try.ok")).susuType(.small).fontWeight(.semibold).foregroundStyle(Palette.ink)
                    Text(verbatim: s("ob.try.okDesc")).susuType(.small).foregroundStyle(Palette.ink2)
                }
            } else {
                Text(verbatim: s("ob.try.say", s("ob.try.ph\(model.phraseIndex + 1)"))).susuType(.small).foregroundStyle(Palette.ink3)
            }
            if model.showCtrlSpaceHint {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: s("ob.try.ctrlSpace")).susuType(.small).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                    Button { model.openKeyboardSettings() } label: { Text(verbatim: s("ob.try.ctrlSpaceBtn")).multilineTextAlignment(.center) }
                        .buttonStyle(.susu(.neutral, size: .small))
                }
                .padding(.horizontal, 20).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.bgGroup, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            }
        }
    }

    // MARK: Step 4

    @ViewBuilder private var wispr: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.wispr {
            case .found:
                note(s("ob.wispr.lock"))
            case .loading:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(verbatim: s("ob.wispr.loading")).susuType(.small).foregroundStyle(Palette.ink2) }
            case .dry(let p):
                table(p, audio: true)
                Text(verbatim: s("ob.wispr.dryNote", ONS.bytes(p.neededBytes, lang), ONS.bytes(p.freeBytes, lang))).susuType(.small).foregroundStyle(Palette.ink3)
            case .noSpace(let p):
                table(p, audio: false)
            case .importing(let v):
                ProgressView(value: v).tint(Palette.accent)
                Text(verbatim: s("ob.wispr.progress", Int(v * 100))).susuType(.small).foregroundStyle(Palette.ink2).monospacedDigit()
            case .done(let p):
                table(p, audio: true)
            case .failed:
                Text(verbatim: s("ob.wispr.failed")).susuType(.small).foregroundStyle(Palette.error)
            }
        }
    }

    private func note(_ t: String) -> some View {
        Text(verbatim: t).susuType(.small).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.bgGroup, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }

    private func table(_ p: WisprPreview, audio: Bool) -> some View {
        var rows: [(String, String)] = [(s("ob.wispr.rDictations"), p.dictations.formatted(.number.locale(L10n.locale(for: lang))))]
        if audio { rows.append((s("ob.wispr.rAudio"), s("ob.wispr.vAudio", p.audioFiles))) }
        rows += [(s("ob.wispr.rVocab"), "\(p.vocabulary)"), (s("ob.wispr.rStyles"), s("ob.wispr.vStyles", p.styleGroups)),
                 (s("ob.wispr.rCalls"), "\(p.calls)"), (s("ob.wispr.rNotes"), "\(p.notes)")]
        return SummaryTable(rows: rows.map { ($0.0, $0.1, false) })
    }

    @ViewBuilder private var wisprFooter: some View {
        switch model.wispr {
        case .found:
            skipButton; Spacer()
            primary("ob.wispr.dryBtn", enabled: model.hooks.wisprDryRun != nil) { model.dryRun() }
        case .loading:
            skipButton; Spacer()
        case .dry(let p):
            skipButton; Spacer()
            primary("ob.wispr.go", enabled: model.hooks.wisprImport != nil) { model.startImport(includeAudio: true, preview: p) }
        case .noSpace(let p):
            skipButton; Spacer()
            primary("ob.wispr.goNoAudio", enabled: model.hooks.wisprImport != nil) { model.startImport(includeAudio: false, preview: p) }
        case .importing:
            Spacer()
            primary("ob.close") { model.advance() }
        case .done, .failed:
            Spacer()
            primary("ob.next") { model.advance() }
        }
    }

    // MARK: Finish

    private var finish: some View {
        let sk = model.skipped
        let permsOk = model.mic == .granted && model.axTrusted
        var rows: [(String, String, Bool)] = [(s("ob.fin.permissions"), s(permsOk ? "ob.fin.permOk" : "ob.fin.permSkipped"), permsOk)]
        let mode: String = {
            switch model.choice {
            case .cloud: return s("ob.fin.modeCloud")
            case .keys: return s(model.hasKeys ? "ob.fin.modeKeys" : "ob.fin.modeKeysNone")
            case .mac: return s(model.mac == .done ? "ob.fin.modeMacOk" : "ob.fin.modeMacNo")
            }
        }()
        rows.append((s("ob.fin.mode"), mode, false))
        rows.append((s("ob.fin.try"), s(sk.contains(.trial) || !model.trialDone ? "ob.fin.trySkipped" : "ob.fin.tryOk"), model.trialDone))
        if model.wisprFound {
            var imported = false
            if case .done = model.wispr { imported = true }
            rows.append((s("ob.fin.import"), s(imported ? "ob.fin.importOk" : "ob.fin.importSkipped"), imported))
        }
        return SummaryTable(rows: rows)
    }
}

// MARK: - Pieces

private struct WizList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 20)
            .background(Palette.bgGroup, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }
}

private struct WizBadge: View {
    let text: String
    let kind: StatusBadge.Kind
    var body: some View {
        HStack(spacing: 6) {
            Circle().strokeBorder(tint, lineWidth: kind == .preparing ? 1.5 : 0)
                .background(Circle().fill(kind == .preparing ? .clear : tint)).frame(width: 6, height: 6)
            Text(verbatim: text).susuType(.caption).foregroundStyle(kind == .ok ? Palette.ok : (kind == .error ? Palette.error : Palette.ink2))
        }
    }
    private var tint: Color { kind == .ok ? Palette.ok : (kind == .error ? Palette.error : Palette.ink3) }
}

private struct SummaryTable: View {
    let rows: [(String, String, Bool)]
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                if i > 0 { Divider().overlay(Palette.line) }
                HStack(alignment: .top, spacing: 16) {
                    Text(verbatim: r.0).susuType(.body).foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    Text(verbatim: r.1).susuType(.body).foregroundStyle(r.2 ? Palette.ok : Palette.ink2).multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 4)
        .background(Palette.bgGroup, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }
}

private struct OptionCard<Content: View>: View {
    let selected: Bool
    let enabled: Bool
    let icon: String
    let title: String
    let desc: String
    let tag: String?
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().strokeBorder(selected ? Palette.accent : Palette.lineStrong, lineWidth: selected ? 0 : 1.5)
                            .background(Circle().fill(selected ? Palette.accent : .clear)).frame(width: 22, height: 22)
                        if selected { Circle().fill(Palette.onAccent).frame(width: 8, height: 8) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: title).susuType(.bodyStrong).foregroundStyle(Palette.ink)
                        Text(verbatim: desc).susuType(.small).foregroundStyle(Palette.ink2)
                    }
                    Spacer(minLength: 8)
                    if let tag {
                        Text(verbatim: tag).susuType(.caption).foregroundStyle(Palette.accentInk).padding(.horizontal, 8).frame(height: 22)
                            .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Palette.ink2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!enabled)
            if selected || !enabled {
                content.padding(.leading, 36).padding(.top, 16).padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .opacity(enabled ? 1 : 0.7)
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .strokeBorder(selected ? Palette.accent : Palette.lineStrong, lineWidth: selected ? 2 : 1))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Multi-line test field. Real dictation inserts into it (focused text view) once the pipeline is wired.
private struct TrialField: View {
    @Binding var text: String
    let placeholder: String
    let label: String
    @FocusState private var focused: Bool
    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 15)).scrollContentBackground(.hidden).focused($focused)
            .padding(.horizontal, 7).padding(.vertical, 6)
            .frame(height: 96)
            .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(focused ? Palette.accent : Palette.lineStrong, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if text.isEmpty { Text(verbatim: placeholder).susuType(.body).foregroundStyle(Palette.ink3).padding(.horizontal, 12).padding(.top, 7).allowsHitTesting(false) }
            }
            .accessibilityLabel(Text(verbatim: label))
            .onAppear { focused = true }
    }
}
