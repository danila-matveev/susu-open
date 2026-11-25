// The «Слова из истории» window (prototype openFind): progress, then ticked candidates, or an empty result.
import SwiftUI
import SusuCore

struct FindWordsSheet: View {
    @StateObject private var vm: FindWordsModel
    let lang: InterfaceLanguage
    /// Called with the entries that were added; empty when the sheet was closed without adding.
    let finish: ([DictionaryEntry]) -> Void
    @State private var adding = false
    @State private var addError: String?

    init(services: AppServices, lang: InterfaceLanguage, finish: @escaping ([DictionaryEntry]) -> Void) {
        _vm = StateObject(wrappedValue: FindWordsModel(services: services))
        self.lang = lang; self.finish = finish
    }

    var body: some View {
        Group {
            switch vm.phase {
            case .reading, .scanning, .judging: loading
            case .results: results
            case .empty(let noEdits): empty(noEdits: noEdits)
            case .failed(let message): failed(message)
            }
        }
        .onAppear { vm.start() }
        .onDisappear { vm.cancel() }
    }

    private var title: some View {
        dt("find.title").susuType(.title).tracking(-0.2).foregroundStyle(Palette.ink)
    }

    private func close() { vm.cancel(); finish([]) }

    // MARK: Progress

    private var progressText: String {
        switch vm.phase {
        case .scanning: DL.format("find.prog", lang, vm.checked, vm.total)
        case .judging: DL.string("find.judging", lang)
        default: DL.string("find.reading", lang)
        }
    }

    @ViewBuilder private var loading: some View {
        title
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            dt("find.busy").susuType(.bodyStrong).foregroundStyle(Palette.ink)
        }
        GeometryReader { geo in
            Capsule().fill(Palette.bgFill)
                .overlay(alignment: .leading) {
                    Capsule().fill(Palette.accent).frame(width: max(6, geo.size.width * vm.fraction))
                }
        }
        .frame(height: 6)
        .susuAnimation(Motion.slow, value: vm.fraction)
        .accessibilityHidden(true)
        Text(verbatim: progressText).susuType(.small).monospacedDigit().foregroundStyle(Palette.ink2)
        VStack(alignment: .leading, spacing: 12) {
            SkeletonLine(width: 0.62); SkeletonLine(width: 0.48); SkeletonLine(width: 0.70)
        }
        HStack {
            EscHint()
            Spacer(minLength: 0)
            Button(action: close) { dt("common.cancel") }.buttonStyle(.susu(.neutral)).keyboardShortcut(.cancelAction)
        }.padding(.top, 4)
    }

    // MARK: Empty / failed

    @ViewBuilder private func empty(noEdits: Bool) -> some View {
        title
        VStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.ok)
            dt("find.none.t").susuType(.title2).foregroundStyle(Palette.ink)
            dt(noEdits ? "find.noedits.d" : "find.none.d").susuType(.small).foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 16).padding(.bottom, 4)
        HStack {
            Spacer(minLength: 0)
            Button(action: close) { dt("common.close") }
                .buttonStyle(.susu(.primary)).keyboardShortcut(.defaultAction)
        }.padding(.top, 4)
    }

    @ViewBuilder private func failed(_ message: String) -> some View {
        title
        Text(verbatim: DL.format("find.error", lang, message)).susuType(.body).foregroundStyle(Palette.error)
        HStack(spacing: Space.s2) {
            Spacer(minLength: 0)
            Button(action: close) { dt("common.cancel") }.buttonStyle(.susu(.neutral)).keyboardShortcut(.cancelAction)
            Button { vm.start() } label: { dt("find.retry") }.buttonStyle(.susu(.primary)).keyboardShortcut(.defaultAction)
        }.padding(.top, 4)
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        let n = vm.rows.count
        Text(verbatim: "\(DL.format("find.found", lang, n)) \(DL.plural("dict.count", n, lang))")
            .susuType(.title).tracking(-0.2).foregroundStyle(Palette.ink)
        dt("find.res.h").susuType(.body).foregroundStyle(Palette.ink2).padding(.top, -8)
        if !vm.isJudged {
            dt("find.unjudged").susuType(.small).foregroundStyle(Palette.callInk)
                .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.callSoft, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(vm.rows) { row in
                    CandidateRow(row: row, checked: vm.selected.contains(row.id), lang: lang) { vm.toggle(row.id) }
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 300)
        .fixedSize(horizontal: false, vertical: vm.rows.count < 6)
        .background(Palette.bgGroup, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .accessibilityLabel(DL.string("find.cands", lang))
        if let addError { Text(verbatim: addError).susuType(.small).foregroundStyle(Palette.error) }
        SheetFooter(primary: "find.add",
                    primaryDetail: vm.selected.isEmpty ? nil : "(\(vm.selected.count))", primaryEnabled: !vm.selected.isEmpty && !adding,
                    onCancel: close, onPrimary: add) {
            Button { vm.toggleAll() } label: {
                dt(vm.selected.count == n ? "find.clear" : "find.all")
            }.buttonStyle(.susu(.plain))
        }
    }

    private func add() {
        guard !vm.selected.isEmpty, !adding else { return }
        adding = true
        Task {
            do {
                let added = try await vm.addSelected()
                adding = false
                finish(added)
            } catch {
                adding = false
                addError = error.localizedDescription
            }
        }
    }
}

private struct CandidateRow: View {
    let row: FindWordsModel.Row
    let checked: Bool
    let lang: InterfaceLanguage
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                CheckBox(isOn: checked)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: row.candidate.after).susuType(.bodyStrong).foregroundStyle(Palette.ink).lineLimit(1)
                    if !row.candidate.before.isEmpty {
                        Text(verbatim: DL.format("find.said", lang, row.candidate.before))
                            .susuType(.small).foregroundStyle(Palette.ink3).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(verbatim: DL.uses(row.judged.count, lang)).susuType(.small).monospacedDigit().foregroundStyle(Palette.ink2)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(hovering ? Palette.bgHover : .clear, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

struct CheckBox: View {
    let isOn: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isOn ? Palette.accent : Palette.bgCard)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isOn ? Palette.accent : Palette.lineStrong, lineWidth: 1.5))
            .overlay { if isOn { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.onAccent) } }
            .frame(width: 20, height: 20)
            .susuAnimation(Motion.fast, value: isOn)
    }
}

private struct SkeletonLine: View {
    let width: CGFloat
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Palette.bgFill)
                .frame(width: geo.size.width * width, height: 12)
        }
        .frame(height: 12)
        .opacity(dim ? 0.5 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityHidden(true)
    }
}
