// Pieces shared by the Dictionary and Snippets screens: header, search, chips, fields, sheet frame, toast.
import SwiftUI
import SusuCore

// MARK: - Header and toolbar

struct DHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let trailing: Trailing
    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing()
    }
    var body: some View {
        HStack(alignment: .top, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: 6) {
                dt(title).susuType(.display).tracking(-0.3).foregroundStyle(Palette.ink)
                dt(subtitle).susuType(.body).foregroundStyle(Palette.ink2).frame(maxWidth: 620, alignment: .leading)
            }
            Spacer(minLength: 0)
            // Buttons keep their full labels; the subtitle wraps first.
            HStack(spacing: Space.s2) { trailing }.fixedSize().padding(.top, 2)
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
    }
}

/// Search with a magnifier, a clear button and a ⌘F hint; ⌘F focuses it.
struct DSearchField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey
    let clearLabel: String
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Palette.ink3)
            TextField("", text: $text, prompt: dt(prompt).foregroundStyle(Palette.ink3))
                .textFieldStyle(.plain).susuType(.body).foregroundStyle(Palette.ink)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.bgCard)
                        .frame(width: 18, height: 18).background(Palette.ink3, in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel(clearLabel)
            } else if !focused {
                Text(verbatim: "⌘F").susuType(.caption).foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 6).frame(height: 20)
                    .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 260, height: Metrics.control)
        .background(focused ? Palette.bgCard : (hovering ? Palette.bgFill : Palette.bgGroup),
                    in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .strokeBorder(focused ? Palette.accent : .clear, lineWidth: 1))
        .background(RoundedRectangle(cornerRadius: Radius.sm + 3, style: .continuous)
            .fill(Palette.focus).padding(-3).opacity(focused ? 1 : 0))
        .onHover { hovering = $0 }
        .background {
            Button("") { focused = true }.keyboardShortcut("f", modifiers: .command).opacity(0).allowsHitTesting(false)
        }
        .susuAnimation(Motion.fast, value: focused)
    }
}

/// Single-choice filter chip with a count.
struct CountChip: View {
    let title: LocalizedStringKey
    let count: Int
    let symbol: String?
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11)).padding(.leading, -2) }
                dt(title)
                Text(verbatim: "\(count)").opacity(0.7).monospacedDigit()
            }
            .susuType(.small).fontWeight(.medium)
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

/// Origin badge: plain tag, or an accent tag with the "learned" icon.
struct OriginTag: View {
    let origin: String
    var body: some View {
        let learned = origin == "learned"
        HStack(spacing: 4) {
            if learned { Image(systemName: "sparkles").font(.system(size: 10)) }
            dt(key)
        }
        .susuType(.caption)
        .foregroundStyle(learned ? Palette.accentInk : Palette.ink2)
        .padding(.horizontal, 8).frame(height: 22)
        .background(learned ? Palette.accentSoft : Palette.bgFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    private var key: LocalizedStringKey {
        switch origin {
        case "learned": "dict.learnedTag"
        case "wispr": "dict.f.wispr"
        case "history": "dict.f.history"
        case "import": "dict.f.import"
        default: "dict.f.manual"
        }
    }
}

// MARK: - Fields

struct DFieldLabel: View {
    let label: LocalizedStringKey
    var optional = false
    var body: some View {
        HStack(spacing: 4) {
            dt(label).foregroundStyle(Palette.ink)
            if optional { dt("common.optional").foregroundStyle(Palette.ink3) }
        }
        .susuType(.label)
    }
}

struct DFieldHint: View {
    let text: Text
    var isError = false
    var body: some View {
        text.susuType(.small).foregroundStyle(isError ? Palette.error : Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Input chrome shared by the one-line and the multi-line field.
private struct FieldChrome: ViewModifier {
    let focused: Bool
    let hovering: Bool
    let isError: Bool
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        content
            .background(Palette.bgCard, in: shape)
            .overlay(shape.strokeBorder(isError ? Palette.error : focused ? Palette.accent : hovering ? Palette.ink3 : Palette.lineStrong,
                                        lineWidth: 1))
            .background(RoundedRectangle(cornerRadius: Radius.sm + 3, style: .continuous)
                .fill(Palette.focus).padding(-3).opacity(focused && !isError ? 1 : 0))
    }
}

struct DTextField: View {
    let placeholder: String
    @Binding var text: String
    var isError = false
    var autofocus = false
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        TextField("", text: $text, prompt: Text(verbatim: placeholder).foregroundStyle(Palette.ink3))
            .textFieldStyle(.plain).susuType(.body).foregroundStyle(Palette.ink)
            .focused($focused)
            .padding(.horizontal, 12).frame(height: Metrics.control)
            .modifier(FieldChrome(focused: focused, hovering: hovering, isError: isError))
            .onHover { hovering = $0 }
            .onAppear { if autofocus { focused = true } }
            .susuAnimation(Motion.fast, value: focused)
    }
}

struct DTextArea: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 112
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        TextEditor(text: $text)
            .scrollContentBackground(.hidden)
            .susuType(.body).foregroundStyle(Palette.ink)
            .focused($focused)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .frame(minHeight: minHeight)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(verbatim: placeholder).susuType(.body).foregroundStyle(Palette.ink3)
                        .padding(.horizontal, 12).padding(.vertical, 10).allowsHitTesting(false)
                }
            }
            .modifier(FieldChrome(focused: focused, hovering: hovering, isError: false))
            .onHover { hovering = $0 }
            .susuAnimation(Motion.fast, value: focused)
    }
}

// MARK: - Sheet

/// A modal inside the window: dim scrim and a white card (prototype `.sheet`). Esc and Enter come from the
/// buttons' keyboard shortcuts (`SheetFooter`).
struct SheetFrame<Content: View>: View {
    var wide = false
    let onDismiss: () -> Void
    let content: Content
    init(wide: Bool = false, onDismiss: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.wide = wide; self.onDismiss = onDismiss; self.content = content()
    }
    var body: some View {
        ZStack {
            Palette.hud.opacity(0.3).contentShape(Rectangle()).onTapGesture(perform: onDismiss)
            VStack(alignment: .leading, spacing: Space.s4) { content }
                .padding(28)
                .frame(width: wide ? 560 : 480)
                .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
                .susuShadow(.pop, radius: Radius.xl)
                .padding(Space.s6)
        }
        .transition(.opacity)
    }
}

struct KeyHint: View {
    let text: String
    var onAccent = false
    var body: some View {
        Text(verbatim: text).susuType(.caption)
            .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
            .foregroundStyle(onAccent ? Palette.onAccent : Palette.ink)
            .background {
                if onAccent {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .strokeBorder(Palette.onAccent.opacity(0.55), lineWidth: 1)
                } else {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Palette.bgCard)
                }
            }
    }
}

struct EscHint: View {
    var body: some View {
        HStack(spacing: 6) {
            KeyHint(text: "Esc")
            dt("common.esc")
        }
        .susuType(.small).foregroundStyle(Palette.ink3)
    }
}

/// Sheet footer: Esc hint on the left, buttons on the right. Cancel = Esc, primary = Return.
struct SheetFooter<Extra: View>: View {
    let primary: LocalizedStringKey
    var primaryDetail: String?
    var showReturnHint = false
    let primaryEnabled: Bool
    let onCancel: () -> Void
    let onPrimary: () -> Void
    let extra: Extra
    init(primary: LocalizedStringKey, primaryDetail: String? = nil, showReturnHint: Bool = false, primaryEnabled: Bool,
         onCancel: @escaping () -> Void, onPrimary: @escaping () -> Void, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.primary = primary; self.primaryDetail = primaryDetail; self.showReturnHint = showReturnHint
        self.primaryEnabled = primaryEnabled; self.onCancel = onCancel; self.onPrimary = onPrimary; self.extra = extra()
    }
    var body: some View {
        HStack(spacing: Space.s2) {
            extra
            Spacer(minLength: 0)
            Button(action: onCancel) { dt("common.cancel") }
                .buttonStyle(.susu(.neutral)).keyboardShortcut(.cancelAction)
            Button(action: onPrimary) {
                HStack(spacing: 8) {
                    dt(primary)
                    if let primaryDetail { Text(verbatim: primaryDetail) }
                    if showReturnHint { KeyHint(text: "↵", onAccent: true) }
                }
            }
            .buttonStyle(.susu(.primary)).keyboardShortcut(.defaultAction).disabled(!primaryEnabled)
        }
        .padding(.top, 4)
    }
}

// MARK: - Toast

struct ToastData: Identifiable {
    let id = UUID()
    var symbol = "checkmark"
    var title: String
    var detail: String?
    var actionTitle: String?
    var action: (@MainActor () -> Void)?
    var duration: Double = 3
}

/// Dark HUD card at the bottom of the window with a thin countdown bar.
struct DictionaryUndoToast: View {
    let toast: ToastData
    let onAction: () -> Void
    @State private var remaining: CGFloat = 1

    var body: some View {
        HStack(alignment: .top, spacing: Space.s3) {
            Image(systemName: toast.symbol).font(.system(size: 16)).foregroundStyle(Palette.hudInk).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: toast.title).susuType(.bodyStrong).foregroundStyle(Palette.hudInk)
                if let detail = toast.detail {
                    Text(verbatim: detail).susuType(.small).foregroundStyle(Palette.hudInk2).lineLimit(1)
                }
                if let actionTitle = toast.actionTitle {
                    HudButton(title: actionTitle, action: onAction).padding(.top, 8)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(minWidth: 320, maxWidth: 480, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(Palette.hud, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Palette.hudLine, lineWidth: 1))
        .overlay(alignment: .bottomLeading) {
            GeometryReader { geo in
                Rectangle().fill(Palette.hudInk2).frame(width: geo.size.width * remaining, height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 12)
        .onAppear { withAnimation(.linear(duration: toast.duration)) { remaining = 0 } }
        .accessibilityElement(children: .combine)
    }
}

private struct HudButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(verbatim: title).susuType(.small).fontWeight(.medium).foregroundStyle(Palette.hudInk)
                .padding(.horizontal, 12).frame(height: Metrics.controlSmall)
                .background(Palette.hudInk.opacity(hovering ? 0.28 : 0.14), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Row helpers

/// Small ghost icon button used in row actions.
struct RowIcon: View {
    let symbol: String
    let label: String
    var tint: Color?
    let action: () -> Void
    var body: some View {
        IconButtonLabeled(symbol: symbol, label: label, tint: tint, action: action)
    }
}

private struct IconButtonLabeled: View {
    let symbol: String
    let label: String
    let tint: Color?
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14))
                .foregroundStyle(hovering ? Palette.ink : (tint ?? Palette.ink3))
                .frame(width: 32, height: 32)
                .background(hovering ? Palette.bgHover : .clear, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
