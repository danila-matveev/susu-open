// Small building blocks used only by the History screen (kept here so Theme/ stays untouched).
import SwiftUI
import SusuCore

/// 32 ghost icon button with a tooltip from the History table.
struct HistoryIconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    var disabledHelp: LocalizedStringKey? = nil
    var isEnabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) { HistoryIconLabel(symbol: symbol, hovering: hovering && isEnabled) }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
            .help(HText(isEnabled ? help : (disabledHelp ?? help)))
            .accessibilityLabel(HText(help))
    }
}

struct HistoryIconLabel: View {
    let symbol: String
    var hovering = false
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14))
            .foregroundStyle(hovering ? Palette.ink : Palette.ink3)
            .frame(width: 32, height: 32)
            .background(hovering ? Palette.bgHover : .clear, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// Filter chip (radio behaviour is done by the caller).
struct HistoryChip: View {
    let title: LocalizedStringKey
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HText(title).susuType(.small).fontWeight(.medium)
                .foregroundStyle(isOn ? Palette.bgCard : (hovering ? Palette.ink : Palette.ink2))
                .padding(.horizontal, 14).frame(height: 30)
                .background(isOn ? Palette.ink : (hovering ? Palette.bgSelected : Palette.bgFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Dropdown that looks like the prototype's `.sel`: white field, hairline border, chevron.
struct HistoryDropdown<Value: Hashable>: View {
    let label: LocalizedStringKey
    @Binding var selection: Value
    let options: [(value: Value, title: Text)]
    var width: CGFloat = 164
    @State private var hovering = false

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, o in o.title.tag(o.value) }
            } label: { HText(label) }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                (options.first { $0.value == selection }?.title ?? HText(label))
                    .susuType(.label).foregroundStyle(Palette.ink).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ink2)
            }
            .padding(.horizontal, 12)
            .frame(width: width, height: Metrics.control)
            .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(hovering ? Palette.ink3 : Palette.lineStrong, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .accessibilityLabel(HText(label))
    }
}

/// Search field with an external focus binding (⌘F) and Esc to clear.
struct HistorySearchField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Palette.ink3)
            TextField("", text: $text, prompt: HText("hist.search").foregroundStyle(Palette.ink3))
                .textFieldStyle(.plain).susuType(.body).foregroundStyle(Palette.ink)
                .focused(focus)
                .onKeyPress(.escape) {
                    guard !text.isEmpty else { return .ignored }
                    text = ""
                    return .handled
                }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.bgCard)
                        .frame(width: 18, height: 18).background(Palette.ink3, in: Circle())
                }
                .buttonStyle(.plain).help(HText("hist.clear"))
            } else if !focus.wrappedValue {
                Text(verbatim: "⌘F").susuType(.caption).foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 6).frame(height: 20)
                    .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 260, height: Metrics.control)
        .background(focus.wrappedValue ? Palette.bgCard : (hovering ? Palette.bgFill : Palette.bgGroup),
                    in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .strokeBorder(focus.wrappedValue ? Palette.accent : .clear, lineWidth: 1))
        .onHover { hovering = $0 }
    }
}

/// 20 square with the first letter of the program (agent = accent, call = amber).
struct HistoryAppIcon: View {
    enum Tone { case plain, agent, call }
    let name: String
    var tone: Tone = .plain
    var body: some View {
        Text(verbatim: String(name.first.map { String($0).uppercased() } ?? "?"))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tone == .agent ? Palette.accentInk : tone == .call ? Palette.callInk : Palette.ink2)
            .frame(width: 20, height: 20)
            .background(tone == .agent ? Palette.accentSoft : tone == .call ? Palette.callSoft : Palette.bgFill,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Key cap, as `kbd` in the prototype.
struct HistoryKbd: View {
    let text: String
    var body: some View {
        Text(verbatim: text).susuType(.label).foregroundStyle(Palette.ink)
            .padding(.horizontal, 8).frame(minWidth: 24, minHeight: 24)
            .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .susuShadow(.card, radius: Radius.sm)
    }
}

/// Wraps children onto several lines.
struct HistoryFlow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(bounds.width, subviews)
        for (i, p) in r.points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing; rowH = max(rowH, size.height); maxW = max(maxW, x - spacing)
        }
        return (points, CGSize(width: maxW, height: y + rowH))
    }
}

/// Dark pill at the bottom (the prototype's toast).
struct HistoryToastView: View {
    let toast: HistoryToast
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: toast.title).susuType(.bodyStrong).foregroundStyle(Palette.hudInk)
                if let d = toast.detail {
                    Text(verbatim: d).susuType(.small).foregroundStyle(Palette.hudInk2)
                }
            }
            Spacer(minLength: 0)
            if let a = toast.actionTitle {
                Button {
                    toast.action?(); dismiss()
                } label: {
                    Text(verbatim: a).susuType(.small).fontWeight(.semibold).foregroundStyle(Palette.hud)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Palette.hudInk, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(width: 340)
        .background(Palette.hud, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Palette.hudLine, lineWidth: 1))
        .susuShadow(.pop, radius: Radius.lg)
        .accessibilityElement(children: .combine)
    }
}

/// `Tag` / `StatusBadge` of the theme, reading the History string table.
struct HistoryTag: View {
    let text: LocalizedStringKey
    var style: Tag.Style = .neutral
    init(_ text: LocalizedStringKey, style: Tag.Style = .neutral) { self.text = text; self.style = style }
    var body: some View {
        HText(text).susuType(.caption)
            .foregroundStyle(style == .accent ? Palette.accentInk : style == .call ? Palette.callInk : Palette.ink2)
            .padding(.horizontal, 8).frame(height: 22)
            .background(style == .accent ? Palette.accentSoft : style == .call ? Palette.callSoft : Palette.bgFill,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct HistoryBadge: View {
    let text: LocalizedStringKey
    var kind: StatusBadge.Kind = .neutral
    init(_ text: LocalizedStringKey, kind: StatusBadge.Kind = .neutral) { self.text = text; self.kind = kind }
    private var tint: Color { kind == .error ? Palette.error : kind == .ok ? Palette.ok : Palette.ink3 }
    var body: some View {
        HStack(spacing: 6) {
            Circle().strokeBorder(tint, lineWidth: kind == .preparing ? 1.5 : 0)
                .background(Circle().fill(kind == .preparing ? .clear : tint))
                .frame(width: 6, height: 6)
            HText(text).susuType(.caption).foregroundStyle(kind == .error ? Palette.error : Palette.ink2)
        }
    }
}
