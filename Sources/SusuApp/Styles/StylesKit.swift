// Small pieces shared by the Styles and Stats screens. They exist because the shared Theme components look
// their text up in the main String Catalog only, while these screens keep their own tables (Styles, Stats).
import SwiftUI
import AppKit
import SusuCore

/// Looks keys up in one String Catalog table for the current interface language.
struct TableStrings {
    let table: String
    let language: InterfaceLanguage

    func callAsFunction(_ key: String) -> String {
        L10n.bundle(for: language).localizedString(forKey: key, value: key, table: table)
    }

    func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: self(key), locale: nil, arguments: args)
    }

    /// `base.one` / `base.few` / `base.many`; English uses `one` and `many` (as "other").
    func plural(_ n: Int, _ base: String) -> String {
        let russian = language == .ru || (language == .system && Locale.current.language.languageCode?.identifier == "ru")
        let form: String
        if russian {
            let m = n % 10, h = n % 100
            form = (m == 1 && h != 11) ? "one" : (m >= 2 && m <= 4 && (h < 12 || h > 14)) ? "few" : "many"
        } else {
            form = n == 1 ? "one" : "many"
        }
        return self("\(base).\(form)")
    }
}

extension ShellModel {
    func strings(_ table: String) -> TableStrings { TableStrings(table: table, language: language) }
}

// MARK: - Layout pieces

/// Screen title block, same metrics as `ScreenHeader` but with plain strings.
struct ScreenHead<Trailing: View>: View {
    let title: String
    let subtitle: String
    let trailing: Trailing
    init(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing()
    }
    var body: some View {
        HStack(alignment: .top, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).susuType(.display).tracking(-0.3).foregroundStyle(Palette.ink)
                Text(subtitle).susuType(.body).foregroundStyle(Palette.ink2)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
    }
}

/// White card with a title: the building block of editor and stats pages.
struct TitledCard<Content: View, Accessory: View>: View {
    let title: String
    let accessory: Accessory
    let content: Content
    init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title; self.accessory = accessory(); self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Text(title).susuType(.title2).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                accessory
            }
            .padding(.bottom, Space.s3)
            content
        }
        .padding(Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .susuShadow(.card, radius: Radius.lg)
    }
}

/// Grey container the cards sit on (prototype `.area`).
struct CardArea<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(spacing: 12) { content }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Palette.bgGroup, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
    }
}

/// Row weights, e.g. 1.4 : 1 : 1 : 1. SwiftUI stacks cannot give unequal flexible shares.
struct WeightedRow: Layout {
    var weights: [CGFloat]
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let widths = columnWidths(width, count: subviews.count)
        var height: CGFloat = 0
        for (v, w) in zip(subviews, widths) { height = max(height, v.sizeThatFits(.init(width: w, height: nil)).height) }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(bounds.width, count: subviews.count)
        var x = bounds.minX
        for (v, w) in zip(subviews, widths) {
            v.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: .init(width: w, height: bounds.height))
            x += w + spacing
        }
    }

    private func columnWidths(_ total: CGFloat, count: Int) -> [CGFloat] {
        let w = Array(weights.prefix(count))
        let sum = w.reduce(0, +)
        guard sum > 0 else { return [] }
        let free = max(0, total - spacing * CGFloat(max(0, w.count - 1)))
        return w.map { free * $0 / sum }
    }
}

// MARK: - Controls

/// Full-width or compact pill tabs with plain string titles; the selected tab is a white pill.
struct PillTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [(value: Value, title: String)]
    var fill = false
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                let on = item.value == selection
                Button { selection = item.value } label: {
                    Text(item.title)
                        .susuType(.label)
                        .foregroundStyle(on ? Palette.ink : Palette.ink2)
                        .lineLimit(1)
                        .padding(.horizontal, fill ? 8 : 16)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .frame(height: 36)
                        .background {
                            if on {
                                Capsule().fill(Palette.bgCard).susuShadow(.card, radius: 18)
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Palette.bgFill, in: Capsule())
        .susuAnimation(Motion.standard, value: selection)
    }
}

/// Single-line text input in the prototype look: white, 1 pt strong line, accent ring on focus.
struct LineField: View {
    @Binding var text: String
    var placeholder = ""
    var mono = false
    @FocusState private var focused: Bool
    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Palette.ink3))
            .textFieldStyle(.plain)
            .font(mono ? .system(size: 13, design: .monospaced) : TypeStyle.body.font)
            .foregroundStyle(Palette.ink)
            .focused($focused)
            .padding(.horizontal, 12)
            .frame(height: Metrics.control)
            .inputChrome(focused: focused)
    }
}

/// Multi-line text input in the same look.
struct AreaField: View {
    @Binding var text: String
    var minHeight: CGFloat = 88
    @FocusState private var focused: Bool
    var body: some View {
        TextEditor(text: $text)
            .scrollContentBackground(.hidden)
            .font(TypeStyle.body.font)
            .lineSpacing(TypeStyle.body.lineSpacing)
            .foregroundStyle(Palette.ink)
            .focused($focused)
            .padding(.horizontal, 7).padding(.vertical, 6)
            .frame(minHeight: minHeight)
            .inputChrome(focused: focused)
    }
}

private struct InputChrome: ViewModifier {
    let focused: Bool
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(focused ? Palette.accent : (hovering ? Palette.ink3 : Palette.lineStrong), lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm + 2, style: .continuous)
                .strokeBorder(Palette.focus, lineWidth: 3).padding(-2).opacity(focused ? 1 : 0))
            .onHover { hovering = $0 }
            .susuAnimation(Motion.fast, value: focused)
    }
}

extension View {
    fileprivate func inputChrome(focused: Bool) -> some View { modifier(InputChrome(focused: focused)) }
}

/// Label above a field, with an optional hint below.
struct Field<Content: View>: View {
    let label: String
    var hint: String?
    let content: Content
    init(_ label: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label; self.hint = hint; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).susuType(.label).foregroundStyle(Palette.ink)
            content
            if let hint { Text(hint).susuType(.small).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// Label and description on the left, control on the right, hairline between rows (inside `GroupedRows`-like blocks).
struct PlainRow<Control: View>: View {
    let title: String
    var detail: String?
    var first = false
    let control: Control
    init(_ title: String, detail: String? = nil, first: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = title; self.detail = detail; self.first = first; self.control = control()
    }
    var body: some View {
        HStack(spacing: Space.s6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).susuType(.bodyStrong).foregroundStyle(Palette.ink)
                if let detail {
                    Text(detail).susuType(.body).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            control
        }
        .padding(.vertical, Space.s4)
        .frame(minHeight: 60)
        .overlay(alignment: .top) { if !first { Rectangle().fill(Palette.line).frame(height: 1) } }
    }
}
