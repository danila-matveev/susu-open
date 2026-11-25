// «Словарь»: words and replacements (prototype window-dictionary.html, spec 1.6).
import SwiftUI
import SusuCore

public struct DictionaryScreen: View {
    @EnvironmentObject private var model: ShellModel

    public init() {}

    public var body: some View {
        DictionaryContent(services: model.services)
    }
}

private enum OriginFilter: String, CaseIterable {
    case all, manual, learned, wispr, history
    /// Entries brought in by «Импорт» (`origin = import`); the chip shows only when there are some.
    case imported = "import"
    var title: LocalizedStringKey {
        switch self {
        case .all: "dict.f.all"
        case .manual: "dict.f.manual"
        case .learned: "dict.f.learned"
        case .wispr: "dict.f.wispr"
        case .history: "dict.f.history"
        case .imported: "dict.f.import"
        }
    }
}

private enum DictSheet: Identifiable {
    case edit(DictionaryEntry?)
    case find
    case importSource
    var id: String {
        switch self {
        case .edit(let e): "edit-\(e?.id ?? "new")"
        case .find: "find"
        case .importSource: "import"
        }
    }
}

private struct DictionaryContent: View {
    @EnvironmentObject private var shell: ShellModel
    @StateObject private var list: EntriesModel
    let services: AppServices
    @State private var filter: OriginFilter = .all
    @State private var query = ""
    @State private var sheet: DictSheet?

    init(services: AppServices) {
        self.services = services
        _list = StateObject(wrappedValue: EntriesModel(scope: .dictionary, service: services.dictionary))
    }

    private var lang: InterfaceLanguage { shell.language }

    private var visible: [DictionaryEntry] {
        let q = normalizedPhrase(query)
        return list.entries.filter { e in
            (filter == .all || e.origin == filter.rawValue)
                && (q.isEmpty || normalizedPhrase(e.phrase).contains(q) || normalizedPhrase(e.replacement ?? "").contains(q))
        }
    }

    private func count(_ f: OriginFilter) -> Int {
        f == .all ? list.entries.count : list.entries.filter { $0.origin == f.rawValue }.count
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                DHeader("dict.title", subtitle: "dict.sub") {
                    // Icon only: with a label the three buttons do not fit a 950-wide window in Russian.
                    Button { sheet = .importSource } label: {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 14))
                    }
                    .buttonStyle(.susu(.neutral))
                    .help(DL.string("dict.import.help", lang))
                    .accessibilityLabel(DL.string("dict.import.help", lang))
                    Button { sheet = .find } label: {
                        HStack(spacing: 8) { Image(systemName: "sparkles").font(.system(size: 14)); dt("dict.find") }
                    }.buttonStyle(.susu(.neutral))
                    Button { sheet = .edit(nil) } label: {
                        HStack(spacing: 8) { Image(systemName: "plus").font(.system(size: 14, weight: .medium)); dt("common.add") }
                    }.buttonStyle(.susu(.primary))
                }
                if !list.entries.isEmpty {
                    HStack(spacing: Space.s4) {
                        HStack(spacing: Space.s2) {
                            ForEach(OriginFilter.allCases.filter { $0 != .imported || count(.imported) > 0 }, id: \.self) { f in
                                CountChip(title: f.title, count: count(f), symbol: f == .learned ? "sparkles" : nil, isOn: filter == f) {
                                    filter = f
                                }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(DL.string("dict.filter", lang))
                        Spacer(minLength: 0)
                        DSearchField(text: $query, prompt: "dict.search", clearLabel: DL.string("common.clear", lang))
                    }
                    .padding(.horizontal, 36).padding(.top, 22)
                }
                content.padding(.top, Space.s5)
            }
            if let sheet { sheetView(sheet) }
            VStack {
                Spacer()
                if let toast = list.toast {
                    DictionaryUndoToast(toast: toast, onAction: list.runToastAction).id(toast.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 24)
            .allowsHitTesting(list.toast != nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .susuAnimation(Motion.standard, value: list.toast?.id)
        .susuAnimation(Motion.standard, value: sheet?.id)
        .task { await list.reload() }
    }

    @ViewBuilder private var content: some View {
        if !list.loaded {
            Color.clear
        } else if list.entries.isEmpty {
            VStack(spacing: 0) {
                EmptyBlock(symbol: "character.book.closed", title: "dict.empty.t", detail: "dict.empty.d") {
                    Button { sheet = .edit(nil) } label: { dt("common.add") }.buttonStyle(.susu(.primary))
                    Button { sheet = .find } label: { dt("dict.find") }.buttonStyle(.susu(.neutral))
                    Button { sheet = .importSource } label: { dt("dict.import") }.buttonStyle(.susu(.neutral))
                }
                Spacer(minLength: 0)
            }
        } else if visible.isEmpty {
            EmptyBlock(symbol: "magnifyingglass", title: "dict.none.t", detail: "dict.none.d") {
                Button { query = ""; filter = .all } label: { dt("dict.reset") }.buttonStyle(.susu(.neutral))
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    wordsCard
                    HStack(spacing: 8) {
                        Image(systemName: "star").font(.system(size: 12))
                        dt("dict.starHint")
                    }
                    .susuType(.small).foregroundStyle(Palette.ink3)
                    .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 4)
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
    }

    private var wordsCard: some View {
        let rows = visible
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                dt("dict.card").susuType(.title).tracking(-0.2).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                Text(verbatim: "\(rows.count) \(DL.plural("dict.count", rows.count, lang))")
                    .susuType(.small).monospacedDigit().foregroundStyle(Palette.ink3)
            }
            .padding(.horizontal, 8).padding(.bottom, 8)
            DictColumns {
                Color.clear
                dt("dict.col.phrase"); dt("dict.col.repl"); dt("dict.col.src")
                dt("dict.col.uses").frame(maxWidth: .infinity, alignment: .trailing)
                Color.clear
            }
            .susuType(.caption).foregroundStyle(Palette.ink3)
            .frame(height: 32)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
            .padding(.bottom, 4)
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, entry in
                    WordRow(entry: entry, isFirst: i == 0, isFresh: list.fresh.contains(entry.id), lang: lang,
                            onStar: { Task { await list.toggleStar(entry) } },
                            onEdit: { sheet = .edit(entry) },
                            onDelete: { Task { await list.delete(entry, language: lang) } })
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 8)
        .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .susuShadow(.card, radius: Radius.lg)
    }

    @ViewBuilder private func sheetView(_ sheet: DictSheet) -> some View {
        switch sheet {
        case .edit(let entry):
            SheetFrame(onDismiss: { self.sheet = nil }) {
                WordSheet(entry: entry, list: list, lang: lang) { self.sheet = nil }
            }
        case .find:
            SheetFrame(wide: true, onDismiss: { self.sheet = nil }) {
                FindWordsSheet(services: services, lang: lang) { added in
                    self.sheet = nil
                    Task {
                        await list.reload()
                        if !added.isEmpty {
                            filter = .all; query = ""
                            list.flash(added.map(\.id))
                            list.show(ToastData(title: DL.format("find.added", lang, added.count), duration: 3))
                        }
                    }
                }
            }
        case .importSource:
            SheetFrame(onDismiss: { self.sheet = nil }) {
                ImportSheet(services: services, lang: lang, close: { self.sheet = nil }) { result in
                    self.sheet = nil
                    Task {
                        await list.reload()
                        filter = .all; query = ""
                        let already = result.alreadyInSusu > 0 ? DL.format("import.already", lang, result.alreadyInSusu) : nil
                        if result.imported > 0 {
                            list.show(ToastData(title: DL.format("import.done", lang, result.imported), detail: already, duration: 4))
                        } else {
                            // Core notes are Russian only.
                            let note = DL.isRussian(lang) ? result.notes.first : nil
                            list.show(ToastData(symbol: "info.circle", title: DL.string("import.none", lang),
                                                detail: already ?? note, duration: 5))
                        }
                    }
                }
            }
        }
    }
}

/// The six grid columns of the words card (prototype `.x-cols` / `.x-drow`).
struct DictColumns<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        // Subviews are laid out by weight through a custom layout so header and rows line up.
        DictGridLayout { content }.padding(.horizontal, 12)
    }
}

struct DictGridLayout: Layout {
    private let fixed: [CGFloat] = [36, 0, 0, 112, 92, 72]
    private let gap: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let widths = columnWidths(total: width)
        var height: CGFloat = 0
        for (i, sub) in subviews.enumerated() where i < widths.count {
            height = max(height, sub.sizeThatFits(ProposedViewSize(width: widths[i], height: nil)).height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(total: bounds.width)
        var x = bounds.minX
        for (i, sub) in subviews.enumerated() where i < widths.count {
            sub.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                      proposal: ProposedViewSize(width: widths[i], height: bounds.height))
            x += widths[i] + gap
        }
    }

    private func columnWidths(total: CGFloat) -> [CGFloat] {
        let fixedSum = fixed.reduce(0, +) + gap * CGFloat(fixed.count - 1)
        let flex = max(0, total - fixedSum)
        // minmax(130, 1.1fr) and minmax(130, 1.2fr)
        let a = max(130, flex * 1.1 / 2.3), b = max(130, flex * 1.2 / 2.3)
        return [36, a, b, 112, 92, 72]
    }
}

private struct WordRow: View {
    let entry: DictionaryEntry
    let isFirst: Bool
    let isFresh: Bool
    let lang: InterfaceLanguage
    let onStar: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var justLearned: Bool {
        entry.origin == "learned" && Date().timeIntervalSince(entry.createdAt) < 60
    }

    var body: some View {
        DictGridLayout {
            Button(action: onStar) {
                Image(systemName: entry.starred ? "star.fill" : "star").font(.system(size: 14))
                    .foregroundStyle(entry.starred ? Palette.accentInk : Palette.ink3)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(DL.string(entry.starred ? "dict.star.off" : "dict.star.on", lang))
            .accessibilityLabel(DL.string(entry.starred ? "dict.star.off" : "dict.star.on", lang))

            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: entry.phrase).susuType(.bodyStrong).foregroundStyle(Palette.ink).lineLimit(1)
                if justLearned { dt("dict.learnedNote").susuType(.caption).foregroundStyle(Palette.ink3).lineLimit(1) }
            }
            if let r = entry.replacement, !r.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "return").font(.system(size: 12)).foregroundStyle(Palette.ink3)
                    Text(verbatim: r).susuType(.body).foregroundStyle(Palette.ink).lineLimit(1)
                }
            } else {
                dt("dict.asIs").susuType(.body).foregroundStyle(Palette.ink3).lineLimit(1)
            }
            OriginTag(origin: entry.origin)
            Text(verbatim: DL.uses(entry.useCount, lang)).susuType(.small).monospacedDigit().foregroundStyle(Palette.ink2)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
            HStack(spacing: 2) {
                RowIcon(symbol: "pencil", label: DL.string("common.edit", lang), action: onEdit)
                RowIcon(symbol: "trash", label: DL.string("common.delete", lang), action: onDelete)
            }
            .opacity(hovering || focused ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 58)
        .background(isFresh ? Palette.accentSoft : (hovering ? Palette.bgGroup : .clear))
        .overlay(alignment: .top) {
            if !isFirst { Rectangle().fill(Palette.line).frame(height: 1).opacity(hovering ? 0 : 1) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onEdit)
        .focusable().focused($focused)
        .onKeyPress(.return) { onEdit(); return .handled }
        .onKeyPress(.delete) { onDelete(); return .handled }
        .susuAnimation(Motion.fast, value: hovering)
        .susuAnimation(Motion.slow, value: isFresh)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.phrase)
    }
}

// MARK: - Add / edit

private struct WordSheet: View {
    let entry: DictionaryEntry?
    @ObservedObject var list: EntriesModel
    let lang: InterfaceLanguage
    let close: () -> Void
    @State private var phrase: String
    @State private var replacement: String
    @State private var saving = false

    init(entry: DictionaryEntry?, list: EntriesModel, lang: InterfaceLanguage, close: @escaping () -> Void) {
        self.entry = entry; self.list = list; self.lang = lang; self.close = close
        _phrase = State(initialValue: entry?.phrase ?? "")
        _replacement = State(initialValue: entry?.replacement ?? "")
    }

    private var duplicate: Bool { list.isDuplicate(phrase: phrase, excluding: entry?.id) }
    private var valid: Bool { !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !duplicate && !saving }

    var body: some View {
        dt(entry == nil ? "dict.sheet.add" : "dict.sheet.edit").susuType(.title).tracking(-0.2).foregroundStyle(Palette.ink)
        VStack(alignment: .leading, spacing: 6) {
            DFieldLabel(label: "dict.f.phrase")
            DTextField(placeholder: DL.string("dict.f.phrase.ph", lang), text: $phrase, isError: duplicate, autofocus: true)
            DFieldHint(text: duplicate ? dt("dict.dup") : dt("dict.f.phrase.h"), isError: duplicate)
        }
        VStack(alignment: .leading, spacing: 6) {
            DFieldLabel(label: "dict.f.repl", optional: true)
            DTextField(placeholder: DL.string("dict.f.repl.ph", lang), text: $replacement)
            DFieldHint(text: dt("dict.f.repl.h"))
        }
        if let failure = list.failure {
            Text(verbatim: failure).susuType(.small).foregroundStyle(Palette.error)
        }
        SheetFooter(primary: entry == nil ? "common.add" : "common.save", showReturnHint: true,
                    primaryEnabled: valid, onCancel: close, onPrimary: submit) { EscHint() }
    }

    private func submit() {
        guard valid else { return }
        saving = true
        Task {
            let saved = await list.save(id: entry?.id, phrase: phrase, replacement: replacement)
            saving = false
            guard let saved else { return }
            close()
            let r = saved.replacement ?? ""
            list.show(ToastData(title: DL.string(entry == nil ? "dict.added" : "common.saved", lang),
                                detail: r.isEmpty ? saved.phrase : "\(saved.phrase) → \(r)", duration: 2.6))
        }
    }
}

// MARK: - Empty states

struct EmptyBlock<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @ViewBuilder let actions: Actions
    var body: some View {
        VStack(spacing: Space.s3) {
            Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(Palette.ink3)
            dt(title).susuType(.title2).foregroundStyle(Palette.ink).multilineTextAlignment(.center)
            dt(detail).susuType(.body).foregroundStyle(Palette.ink2).multilineTextAlignment(.center).frame(maxWidth: 340)
            HStack(spacing: Space.s2) { actions }.padding(.top, 4)
        }
        .padding(.horizontal, 24).padding(.vertical, 48)
        .frame(maxWidth: .infinity)
    }
}
