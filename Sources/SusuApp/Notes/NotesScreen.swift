// «Заметки» (spec 1.6): list with search and tag filter on the left, the open note on the right.
// Matches docs/design/prototype/window-notes.html.
import SwiftUI
import SusuCore

public struct NotesScreen: View {
    @EnvironmentObject private var shell: ShellModel

    public init() {}

    public var body: some View {
        NotesContent(services: shell.services)
    }
}

private struct NotesContent: View {
    @EnvironmentObject private var shell: ShellModel
    @ObservedObject private var bridge = NotesBridge.shared
    @StateObject private var model: NotesModel

    init(services: AppServices) {
        _model = StateObject(wrappedValue: NotesModel(services: services))
    }

    private var lang: InterfaceLanguage { shell.language }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.loaded && model.all.isEmpty && model.query.isEmpty {
                emptyList
            } else {
                HStack(alignment: .top, spacing: Space.s3) {
                    leftPanel.frame(width: 322)
                    editorArea
                }
                .padding(.top, Space.s5)
                .padding(.leading, Space.s6).padding(.trailing, Space.s3).padding(.bottom, Space.s3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) { toast }
        .task { await model.observe() }
        .onDisappear { Task { await model.flush() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: 10) {
                Text("nav.notes", bundle: .module).susuType(.display).tracking(-0.3).foregroundStyle(Palette.ink)
                Text(countText).susuType(.body).foregroundStyle(Palette.ink2).frame(minHeight: 22)
            }
            Spacer(minLength: 0)
            NotesSearchField(text: $model.query)
                .frame(width: 240)
            if bridge.startVoiceNote != nil {
                Button { bridge.startVoiceNote?() } label: {
                    Image(systemName: "mic").font(.system(size: 16)).foregroundStyle(Palette.ink2)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Palette.bgCard).susuShadow(.card, radius: 20))
                }
                .buttonStyle(.plain)
                .help(NS.string("notes.micHelp", lang))
                .accessibilityLabel(NS.text("notes.micHelp"))
            }
            Button { Task { await model.newNote() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                    NS.text("notes.new")
                    Text("⌘N").susuType(.caption).foregroundStyle(Palette.onAccent.opacity(0.75))
                        .padding(.horizontal, 6).frame(height: 20)
                        .background(Palette.onAccent.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .buttonStyle(.susu(.primary))
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, 36).padding(.top, 28)
    }

    private var countText: String {
        guard model.loaded, !model.all.isEmpty else { return "" }
        return model.all.count == 1 ? NS.string("notes.count1", lang) : NS.string("notes.count", lang, model.all.count)
    }

    // MARK: Left panel

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            NotesFlowLayout {
                NotesChip(title: NS.string("notes.all", lang), isOn: model.tagFilter == nil) { model.tagFilter = nil }
                ForEach(model.tags, id: \.self) { t in
                    NotesChip(title: "#" + t, isOn: model.tagFilter == t) { model.tagFilter = (model.tagFilter == t ? nil : t) }
                }
            }
            .padding(.leading, Space.s3).padding(.bottom, Space.s3)

            if model.visible.isEmpty {
                noResults
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.visible) { n in
                            NoteRow(note: n, selected: n.id == model.selectedID, query: model.query, lang: lang) {
                                Task { await model.select(n.id) }
                            }
                        }
                    }
                    .padding(.trailing, Space.s2).padding(.bottom, Space.s3)
                }
                .accessibilityLabel(NS.text("notes.list"))
            }
        }
    }

    private var noResults: some View {
        VStack(spacing: Space.s3) {
            Image(systemName: "magnifyingglass").font(.system(size: 32, weight: .light)).foregroundStyle(Palette.ink3)
            NS.text("notes.noResults").susuType(.body).foregroundStyle(Palette.ink2)
            Button { model.query = ""; model.tagFilter = nil } label: { NS.text("notes.resetSearch") }
                .buttonStyle(.susu(.neutral))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 32).padding(.horizontal, Space.s4)
    }

    // MARK: Right panel

    private var editorArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(Palette.bgGroup)
            if let note = model.selected {
                NoteEditor(note: note, model: model, lang: lang, titlePending: bridge.titlePending.contains(note.id))
                    .id(note.id)
                    .padding(Space.s3)
            } else {
                VStack(spacing: Space.s3) {
                    Image(systemName: "note.text").font(.system(size: 32, weight: .light)).foregroundStyle(Palette.ink3)
                    NS.text("notes.pick").susuType(.body).foregroundStyle(Palette.ink2)
                }
                .padding(Space.s6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyList: some View {
        VStack(spacing: Space.s3) {
            Image(systemName: "note.text").font(.system(size: 32, weight: .light)).foregroundStyle(Palette.ink3)
            NS.text("notes.emptyTitle").susuType(.body).foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            NS.text("notes.emptySub").susuType(.small).foregroundStyle(Palette.ink3)
            Button { Task { await model.newNote() } } label: {
                HStack(spacing: 8) { Image(systemName: "plus").font(.system(size: 13, weight: .semibold)); NS.text("notes.new") }
            }
            .buttonStyle(.susu(.primary)).padding(.top, Space.s1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Toast

    @ViewBuilder private var toast: some View {
        if let t = model.toast {
            HStack(spacing: Space.s3) {
                Text(t.text).susuType(.small).foregroundStyle(Palette.hudInk)
                if let id = t.undoID {
                    Button { Task { await model.undo(id) } } label: { NS.text("notes.undo") }
                        .buttonStyle(.plain).susuType(.small).fontWeight(.semibold).foregroundStyle(Palette.accent)
                }
            }
            .padding(.horizontal, Space.s4).frame(height: 44)
            .background(Palette.hud, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .susuShadow(.pop, radius: Radius.md)
            .padding(.bottom, Space.s5)
            .transition(.opacity)
        }
    }
}

// MARK: - Pieces

private struct NotesChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(verbatim: title).susuType(.small).fontWeight(.medium)
                .foregroundStyle(isOn ? Palette.bgCard : (hovering ? Palette.ink : Palette.ink2))
                .padding(.horizontal, 14).frame(height: 30)
                .background(isOn ? Palette.ink : (hovering ? Palette.bgSelected : Palette.bgFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .susuAnimation(Motion.fast, value: hovering)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct NotesSearchField: View {
    @Binding var text: String
    @EnvironmentObject private var shell: ShellModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Palette.ink3)
            TextField("", text: $text, prompt: Text(NS.string("notes.search", shell.language)).foregroundStyle(Palette.ink3))
                .textFieldStyle(.plain).susuType(.body).foregroundStyle(Palette.ink).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.bgCard)
                        .frame(width: 18, height: 18).background(Palette.ink3, in: Circle())
                }
                .buttonStyle(.plain).help(NS.string("notes.clear", shell.language))
            }
        }
        .padding(.horizontal, 10).frame(height: Metrics.control)
        .background(focused ? Palette.bgCard : Palette.bgGroup, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(focused ? Palette.accent : .clear, lineWidth: 1))
        .onExitCommand { text = ""; focused = false }
    }
}

private struct SourceMark: View {
    let origin: String
    let short: Bool
    let lang: InterfaceLanguage
    var body: some View {
        switch origin {
        case "hotkey":
            HStack(spacing: 6) {
                kbd
                if !short { Text(NS.string("notes.srcCmd", lang)).susuType(.caption).foregroundStyle(Palette.ink2) }
            }
        case "agent": chip(NS.string(short ? "notes.shAgent" : "notes.srcAgent", lang), accent: true)
        case "wispr": chip(NS.string(short ? "notes.shWispr" : "notes.srcWispr", lang), accent: false)
        default: EmptyView()
        }
    }
    private var kbd: some View {
        Text("⌘").susuType(.caption).foregroundStyle(Palette.ink)
            .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
            .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .susuShadow(.card, radius: Radius.sm)
    }
    private func chip(_ s: String, accent: Bool) -> some View {
        Text(verbatim: s).susuType(.caption).foregroundStyle(accent ? Palette.accentInk : Palette.ink2)
            .padding(.horizontal, 8).frame(height: 22)
            .background(accent ? Palette.accentSoft : Palette.bgFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct NoteRow: View {
    let note: Note
    let selected: Bool
    let query: String
    let lang: InterfaceLanguage
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(NS.highlighted(title, query: query)).susuType(.bodyStrong).foregroundStyle(Palette.ink).lineLimit(1)
                Text(NS.highlighted(firstLine, query: query)).susuType(.small).foregroundStyle(Palette.ink2).lineLimit(1)
                HStack(spacing: 6) {
                    SourceMark(origin: note.origin, short: true, lang: lang)
                    ForEach(note.tags.prefix(2), id: \.self) { t in
                        Text(verbatim: "#" + t).susuType(.caption).foregroundStyle(Palette.ink2)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(Palette.bgFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    Spacer(minLength: 6)
                    Text(NS.date(note.createdAt, short: true, lang)).susuType(.caption).foregroundStyle(Palette.ink3).lineLimit(1).fixedSize().layoutPriority(1)
                }
                .frame(minHeight: 22).padding(.top, 2)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Palette.accentSoft : (hovering ? Palette.bgGroup : .clear),
                        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .susuAnimation(Motion.fast, value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var title: String {
        let t = note.title ?? ""
        return t.isEmpty ? NS.string("notes.untitled", lang) : t
    }
    private var firstLine: String {
        let l = note.firstLine
        return l.isEmpty ? NS.string("notes.blank", lang) : l
    }
}

// MARK: - Editor

private struct NoteEditor: View {
    let note: Note
    let model: NotesModel
    let lang: InterfaceLanguage
    let titlePending: Bool

    @State private var title: String
    @State private var text: String
    @State private var tags: [String]
    @State private var newTag = ""
    @FocusState private var titleFocused: Bool
    @FocusState private var tagFocused: Bool

    init(note: Note, model: NotesModel, lang: InterfaceLanguage, titlePending: Bool) {
        self.note = note; self.model = model; self.lang = lang; self.titlePending = titlePending
        _title = State(initialValue: note.title ?? "")
        _text = State(initialValue: note.text ?? "")
        _tags = State(initialValue: note.tags)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                top
                titleRow
                tagRow
                audio
                bodyField
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .susuShadow(.card, radius: Radius.lg)
        .onAppear { if (note.title ?? "").isEmpty && (note.text ?? "").isEmpty && note.origin == "manual" { titleFocused = true } }
        // The model may write a title later (editor model): take it unless the user is typing in the field.
        .onChange(of: note.title) { _, new in if !titleFocused, (new ?? "") != title { title = new ?? "" } }
        .onChange(of: title) { _, _ in push() }
        .onChange(of: text) { _, _ in push() }
        .onChange(of: tags) { _, _ in push() }
    }

    private func push() { model.edit(id: note.id, title: title, text: text, tags: tags) }

    private var top: some View {
        HStack(spacing: Space.s3) {
            Text(NS.date(note.createdAt, short: false, lang)).susuType(.small).foregroundStyle(Palette.ink3)
            SourceMark(origin: note.origin, short: false, lang: lang)
            Spacer(minLength: 0)
            Menu {
                Button { model.copyText(note, toast: NS.string("notes.copied", lang)) } label: { NS.text("notes.copy") }
                Button { model.downloadAudio(note, toast: NS.string("notes.audioSaved", lang)) } label: { NS.text("notes.download") }
                    .disabled(model.store.audioURL(for: note) == nil)
                Divider()
                Button(role: .destructive) {
                    Task { await model.delete(note.id, text: NS.string("notes.deleted", lang)) }
                } label: { NS.text("notes.delete") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14)).foregroundStyle(Palette.ink3)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(NS.string("notes.more", lang))
            .accessibilityLabel(NS.text("notes.more"))
        }
        .frame(minHeight: 32)
    }

    private var titleRow: some View {
        HStack(spacing: Space.s3) {
            TextField("", text: $title, prompt: Text(NS.string("notes.untitled", lang)).foregroundStyle(Palette.ink3))
                .textFieldStyle(.plain).susuType(.title).tracking(-0.2).foregroundStyle(Palette.ink)
                .focused($titleFocused)
                .padding(.horizontal, 10).frame(height: 40)
                .background(titleFocused ? Palette.bgGroup : .clear, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(titleFocused ? Palette.focus : .clear, lineWidth: 3))
                .padding(.leading, -10)
                .accessibilityLabel(NS.text("notes.titleA"))
            if titlePending {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    NS.text("notes.pending").susuType(.small).foregroundStyle(Palette.ink2)
                }
                .fixedSize()
            }
        }
    }

    private var tagRow: some View {
        NotesFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(tags, id: \.self) { t in
                HStack(spacing: 2) {
                    Text(verbatim: "#" + t).susuType(.small).foregroundStyle(Palette.ink2)
                    Button { tags.removeAll { $0 == t } } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.ink3)
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(NS.string("notes.tagRemove", lang, t))
                    .accessibilityLabel(Text(NS.string("notes.tagRemove", lang, t)))
                }
                .padding(.leading, 10).padding(.trailing, 4).frame(height: 26)
                .background(Palette.bgFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            TextField("", text: $newTag, prompt: Text(NS.string("notes.tagAdd", lang)).foregroundStyle(Palette.ink3))
                .textFieldStyle(.plain).susuType(.small).foregroundStyle(Palette.ink)
                .focused($tagFocused)
                .padding(.horizontal, 10).frame(width: 104, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(tagFocused ? Palette.accent : Palette.lineStrong,
                                  style: StrokeStyle(lineWidth: 1, dash: tagFocused ? [] : [3, 3])))
                .onSubmit(addTag)
                .onKeyPress(.delete) {
                    guard newTag.isEmpty, !tags.isEmpty else { return .ignored }
                    tags.removeLast(); return .handled
                }
                .accessibilityLabel(NS.text("notes.tagAddA"))
        }
    }

    private func addTag() {
        let t = newTag.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
        newTag = ""
        if !t.isEmpty, !tags.contains(t) { tags.append(String(t.prefix(24))) }
        tagFocused = true
    }

    @ViewBuilder private var audio: some View {
        if let url = model.store.audioURL(for: note) {
            PlayerBar(url: url, lang: lang)
        } else {
            let hand = note.audioPath == nil && note.origin == "manual"
            Text(hand ? NS.string("notes.noAudioHand", lang)
                      : NS.string("notes.noAudio", lang) + (note.origin == "wispr" ? NS.string("notes.noAudioWispr", lang) : ""))
                .susuType(.small).foregroundStyle(Palette.ink2)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.bgGroup, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
    }

    private var bodyField: some View {
        TextEditor(text: $text)
            .font(.system(size: 15)).lineSpacing(5).foregroundStyle(Palette.ink)
            .scrollContentBackground(.hidden)
            .padding(.leading, -5)
            .frame(minHeight: 240)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    NS.text("notes.bodyPh").susuType(.body).foregroundStyle(Palette.ink3).padding(.top, 1).allowsHitTesting(false)
                }
            }
            .accessibilityLabel(NS.text("notes.bodyA"))
    }
}

private struct PlayerBar: View {
    @StateObject private var player: NotePlayer
    let lang: InterfaceLanguage

    init(url: URL, lang: InterfaceLanguage) {
        _player = StateObject(wrappedValue: NotePlayer(url: url))
        self.lang = lang
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 12))
                    .foregroundStyle(Palette.onAccent).frame(width: 32, height: 32).background(Palette.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .help(NS.string(player.isPlaying ? "notes.pause" : "notes.play", lang))
            .accessibilityLabel(Text(NS.string(player.isPlaying ? "notes.pause" : "notes.play", lang)))
            Text(NotePlayer.mmss(player.progress * player.duration)).monospacedDigit()
            Scrubber(progress: player.progress) { player.seek($0) }
                .frame(width: 150, height: 20)
                .accessibilityLabel(NS.text("notes.position"))
            Text(NotePlayer.mmss(player.duration)).monospacedDigit()
            Button { player.cycleSpeed() } label: {
                Text(verbatim: speedLabel).susuType(.caption).foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 8).frame(height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(NS.string("notes.speed", lang))
        }
        .susuType(.caption).foregroundStyle(Palette.ink2)
        .padding(.leading, 6).padding(.trailing, 16).frame(height: 44)
        .background(Palette.bgGroup, in: Capsule())
        .onDisappear { player.stop() }
    }

    private var speedLabel: String {
        let sep = lang == .en ? "." : ","
        return player.speed == 1.5 ? "1\(sep)5×" : "\(Int(player.speed))×"
    }
}

private struct Scrubber: View {
    let progress: Double
    let onSeek: (Double) -> Void
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.bgFill).frame(height: 4)
                Capsule().fill(Palette.accent).frame(width: g.size.width * progress, height: 4)
                Circle().fill(Palette.accent).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Palette.bgGroup, lineWidth: 3).frame(width: 18, height: 18))
                    .offset(x: g.size.width * progress - 6)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { onSeek(Double($0.location.x / g.size.width)) })
        }
        .accessibilityElement().accessibilityValue("\(Int(progress * 100))%")
        .accessibilityAdjustableAction { dir in onSeek(progress + (dir == .increment ? 0.1 : -0.1)) }
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func sampleServices() -> AppServices {
    let s = AppServices.temporary()
    Task {
        let n = NotesStore(database: s.database, baseDirectory: s.dataDirectory)
        let now = Date()
        _ = try? await n.create(title: "Идея для упаковки", text: "На внутренней стороне коробки напечатать короткую инструкцию по уходу.", tags: ["упаковка", "идеи"], origin: "hotkey", now: now)
        _ = try? await n.create(title: "Вопросы Игорю по образцам", text: "Спросить Игоря про сроки пошива образца.", tags: ["поставки"], origin: "agent", now: now.addingTimeInterval(-3600))
    }
    return s
}

#Preview("Notes light") {
    NotesScreen().environmentObject(ShellModel(services: sampleServices())).frame(width: 1100, height: 760).preferredColorScheme(.light)
}
#Preview("Notes dark") {
    NotesScreen().environmentObject(ShellModel(services: sampleServices())).frame(width: 1100, height: 760).preferredColorScheme(.dark)
}
#endif
