// S-COMPARE: two versions of a text side by side.
import SwiftUI
import SusuCore

struct HistoryCompareSheet: View {
    let state: CompareState
    @ObservedObject var model: HistoryModel

    private var lang: InterfaceLanguage { model.language }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.line)
            HStack(alignment: .top, spacing: 0) {
                leftColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                Rectangle().fill(Palette.line).frame(width: 1)
                rightColumn.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 150)
            Divider().overlay(Palette.line)
            HStack {
                Spacer()
                Button { model.keepOriginal() } label: { HText("hist.cmp.close") }
                    .buttonStyle(.susu(.neutral)).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(maxWidth: 900)
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .susuShadow(.pop, radius: Radius.xl)
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(HText("hist.cmp.title"))
    }

    // MARK: header

    private var currentModel: CompareOption? { state.options.models.first(where: \.isCurrent) }
    private var currentStyle: CompareOption? { state.options.styles.first(where: \.isCurrent) }

    private func modelTitle(_ id: String?) -> String {
        (state.options.models.first { $0.id == id } ?? currentModel)?.title ?? "—"
    }
    private func styleTitle(_ id: String?) -> String {
        (state.options.styles.first { $0.id == id } ?? currentStyle)?.title ?? "—"
    }

    private func subtitle(_ m: String?, _ s: String?) -> String {
        [modelTitle(m), styleTitle(s)].filter { $0 != "—" }.joined(separator: " · ")
    }

    private func optionTitle(_ o: CompareOption) -> Text {
        var s = o.title
        if o.isCurrent { s += HL.string("hist.cmp.current", lang) }
        if !o.hasKey { s += HL.string("hist.cmp.nokey", lang) }
        return Text(verbatim: s)
    }

    private var header: some View {
        HStack(spacing: 8) {
            HText("hist.cmp.title").susuType(.title2).foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            if !state.options.models.isEmpty {
                HistoryDropdown(
                    label: "hist.cmp.model",
                    selection: Binding(
                        get: { state.choice.modelID ?? currentModel?.id ?? "" },
                        set: { model.setCompare(model: $0, style: state.choice.styleID) }),
                    options: state.options.models.map { (value: $0.id, title: optionTitle($0)) }, width: 250)
            }
            if !state.options.styles.isEmpty {
                HistoryDropdown(
                    label: "hist.cmp.style",
                    selection: Binding(
                        get: { state.choice.styleID ?? currentStyle?.id ?? "" },
                        set: { model.setCompare(model: state.choice.modelID, style: $0) }),
                    options: state.options.styles.map { (value: $0.id, title: optionTitle($0)) }, width: 200)
            }
            Button { model.keepOriginal() } label: { HistoryIconLabel(symbol: "xmark") }
                .buttonStyle(.plain).help(HText("hist.cmp.close"))
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    // MARK: columns

    private var original: String { state.record.displayText }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            label("hist.cmp.was", subtitle(currentModel?.id, currentStyle?.id))
            Text(verbatim: original).susuType(.body).foregroundStyle(Palette.ink).frame(maxWidth: .infinity, alignment: .leading)
            Button { model.keepOriginal() } label: { HText("hist.cmp.keep") }.buttonStyle(.susu(.neutral, size: .small))
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            label("hist.cmp.became", subtitle(state.choice.modelID, state.choice.styleID))
            switch state.phase {
            case .loading:
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        HText("hist.cmp.wait").susuType(.small).foregroundStyle(Palette.ink2)
                    }
                    skeleton(1); skeleton(0.8); skeleton(0.6)
                }
            case .ready(let text):
                Text(diff(original, text)).susuType(.body).foregroundStyle(Palette.ink).frame(maxWidth: .infinity, alignment: .leading)
                Button { model.keepCompared(text) } label: { HText("hist.cmp.keep") }.buttonStyle(.susu(.primary, size: .small))
            case .failed(let message):
                Text(verbatim: message).susuType(.body).foregroundStyle(Palette.error).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
    }

    private func label(_ key: LocalizedStringKey, _ rest: String) -> some View {
        (HText(key).fontWeight(.semibold).foregroundStyle(Palette.ink) + Text(verbatim: " · " + rest))
            .susuType(.small).foregroundStyle(Palette.ink3).lineLimit(2)
    }

    private func skeleton(_ width: CGFloat) -> some View {
        GeometryReader { g in
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Palette.bgFill).frame(width: g.size.width * width)
        }.frame(height: 12)
    }

    /// New text with the words that were not in the old one marked.
    private func diff(_ old: String, _ new: String) -> AttributedString {
        func norm(_ w: Substring) -> String { w.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let known = Set(old.split(whereSeparator: \.isWhitespace).map(norm))
        var out = AttributedString()
        for (i, w) in new.split(whereSeparator: \.isWhitespace).enumerated() {
            var piece = AttributedString((i == 0 ? "" : " ") + w)
            if !known.contains(norm(w)) {
                if let r = piece.range(of: String(w)) { piece[r].backgroundColor = Palette.accentSoft }
            }
            out += piece
        }
        return out
    }
}
