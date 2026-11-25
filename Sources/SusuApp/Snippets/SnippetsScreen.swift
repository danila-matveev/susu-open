// «Сниппеты»: a short trigger phrase pastes a long text (prototype window-snippets.html, spec 1.6, 3.7).
import SwiftUI
import SusuCore

public struct SnippetsScreen: View {
    @EnvironmentObject private var model: ShellModel

    public init() {}

    public var body: some View {
        SnippetsContent(services: model.services)
    }
}

private struct SnippetsContent: View {
    @EnvironmentObject private var shell: ShellModel
    @StateObject private var list: EntriesModel
    @State private var query = ""
    @State private var sheet: SnippetSheetTarget?

    init(services: AppServices) {
        _list = StateObject(wrappedValue: EntriesModel(scope: .snippets, service: services.dictionary))
    }

    private var lang: InterfaceLanguage { shell.language }

    private var visible: [DictionaryEntry] {
        let q = normalizedPhrase(query)
        guard !q.isEmpty else { return list.entries }
        return list.entries.filter {
            normalizedPhrase($0.phrase).contains(q) || normalizedPhrase($0.replacement ?? "").contains(q)
        }
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                DHeader("snip.title", subtitle: "snip.sub") {
                    Button { sheet = SnippetSheetTarget(entry: nil) } label: {
                        HStack(spacing: 8) { Image(systemName: "plus").font(.system(size: 14, weight: .medium)); dt("common.add") }
                    }.buttonStyle(.susu(.primary))
                }
                if !list.entries.isEmpty {
                    HStack {
                        Spacer(minLength: 0)
                        DSearchField(text: $query, prompt: "snip.search", clearLabel: DL.string("common.clear", lang))
                    }
                    .padding(.horizontal, 36).padding(.top, 22)
                }
                content.padding(.top, Space.s5)
            }
            if let sheet {
                SheetFrame(wide: true, onDismiss: { self.sheet = nil }) {
                    SnippetSheet(entry: sheet.entry, list: list, lang: lang) { self.sheet = nil }
                }
            }
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
                EmptyBlock(symbol: "chevron.left.forwardslash.chevron.right", title: "snip.empty.t", detail: "snip.empty.d") {
                    Button { sheet = SnippetSheetTarget(entry: nil) } label: { dt("common.add") }.buttonStyle(.susu(.primary))
                }
                Spacer(minLength: 0)
            }
        } else if visible.isEmpty {
            EmptyBlock(symbol: "magnifyingglass", title: "snip.none.t", detail: "snip.none.d") {
                Button { query = "" } label: { dt("snip.reset") }.buttonStyle(.susu(.neutral))
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { i, entry in
                        SnippetRow(entry: entry, isFirst: i == 0, isFresh: list.fresh.contains(entry.id), lang: lang,
                                   onEdit: { sheet = SnippetSheetTarget(entry: entry) },
                                   onDelete: { Task { await list.delete(entry, language: lang) } })
                    }
                }
                .padding(.horizontal, 28)
                .background(Palette.bgGroup, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
    }
}

private struct SnippetSheetTarget: Identifiable {
    let entry: DictionaryEntry?
    var id: String { entry?.id ?? "new" }
}

private struct SnippetRow: View {
    let entry: DictionaryEntry
    let isFirst: Bool
    let isFresh: Bool
    let lang: InterfaceLanguage
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "mic").font(.system(size: 14)).foregroundStyle(Palette.ink3)
                    Text(verbatim: "«\(entry.phrase)»").susuType(.bodyStrong).foregroundStyle(Palette.ink).lineLimit(1)
                }
                Text(verbatim: entry.replacement ?? "").susuType(.body).foregroundStyle(Palette.ink2)
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Text(verbatim: DL.uses(entry.useCount, lang)).susuType(.small).monospacedDigit()
                    .foregroundStyle(Palette.ink3).lineLimit(1).fixedSize()
                HStack(spacing: 2) {
                    RowIcon(symbol: "pencil", label: DL.string("common.edit", lang), action: onEdit)
                    RowIcon(symbol: "trash", label: DL.string("common.delete", lang), action: onDelete)
                }
                .opacity(hovering || focused ? 1 : 0)
            }
        }
        .padding(.vertical, 16)
        .frame(minHeight: 68)
        .background(isFresh ? Palette.accentSoft : .clear)
        .overlay(alignment: .top) { if !isFirst { Rectangle().fill(Palette.line).frame(height: 1) } }
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

private struct SnippetSheet: View {
    let entry: DictionaryEntry?
    @ObservedObject var list: EntriesModel
    let lang: InterfaceLanguage
    let close: () -> Void
    @State private var trigger: String
    @State private var text: String
    @State private var saving = false

    init(entry: DictionaryEntry?, list: EntriesModel, lang: InterfaceLanguage, close: @escaping () -> Void) {
        self.entry = entry; self.list = list; self.lang = lang; self.close = close
        _trigger = State(initialValue: entry?.phrase ?? "")
        _text = State(initialValue: entry?.replacement ?? "")
    }

    private var duplicate: Bool { list.isDuplicate(phrase: trigger, excluding: entry?.id) }
    private var trimmedTrigger: String { trigger.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { !trimmedTrigger.isEmpty && !trimmedText.isEmpty && !duplicate && !saving }

    var body: some View {
        dt(entry == nil ? "snip.sheet.add" : "snip.sheet.edit").susuType(.title).tracking(-0.2).foregroundStyle(Palette.ink)
        VStack(alignment: .leading, spacing: 6) {
            DFieldLabel(label: "snip.f.trig")
            DTextField(placeholder: DL.string("snip.f.trig.ph", lang), text: $trigger, isError: duplicate, autofocus: true)
            DFieldHint(text: duplicate ? dt("snip.dup") : dt("snip.f.trig.h"), isError: duplicate)
        }
        VStack(alignment: .leading, spacing: 6) {
            DFieldLabel(label: "snip.f.text")
            DTextArea(placeholder: DL.string("snip.f.text.ph", lang), text: $text)
        }
        preview
        if let failure = list.failure { Text(verbatim: failure).susuType(.small).foregroundStyle(Palette.error) }
        SheetFooter(primary: entry == nil ? "common.add" : "common.save", primaryEnabled: valid,
                    onCancel: close, onPrimary: submit) { EscHint() }
    }

    /// «Скажешь → Вставится», updated while typing.
    private var preview: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                HStack(spacing: 6) { Image(systemName: "mic").font(.system(size: 12)); dt("snip.say") }
                    .susuType(.small).foregroundStyle(Palette.ink3)
                Text(verbatim: trimmedTrigger.isEmpty ? "«…»" : "«\(trimmedTrigger)»")
                    .susuType(.bodyStrong).foregroundStyle(Palette.ink).lineLimit(1)
            }
            GridRow {
                HStack(spacing: 6) { Image(systemName: "return").font(.system(size: 12)); dt("snip.paste") }
                    .susuType(.small).foregroundStyle(Palette.ink3)
                Text(verbatim: trimmedText.isEmpty ? "…" : trimmedText)
                    .susuType(.body).foregroundStyle(Palette.ink2).lineLimit(3).multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Palette.bgGroup, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func submit() {
        guard valid else { return }
        saving = true
        Task {
            let saved = await list.save(id: entry?.id, phrase: trigger, replacement: text)
            saving = false
            guard let saved else { return }
            close()
            list.show(ToastData(title: DL.string(entry == nil ? "snip.added" : "common.saved", lang),
                                detail: "«\(saved.phrase)»", duration: 2.6))
        }
    }
}
