// Reusable components every screen uses. Small on purpose; see docs/design/prototype/components.css.
// All text parameters are LocalizedStringKey and resolve in this module's String Catalog.
import SwiftUI

// MARK: - Cards and rows

/// The one white card of a window: radius 20, soft shadow. The shell insets it by 8.
public struct ContentCard<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
            .susuShadow(.card, radius: Radius.xl)
    }
}

/// Screen title block: display title, optional meta line, optional trailing controls (search, buttons).
public struct ScreenHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let trailing: Trailing
    public init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing()
    }
    public var body: some View {
        HStack(alignment: .top, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title, bundle: .module).susuType(.display).tracking(-0.3).foregroundStyle(Palette.ink)
                if let subtitle {
                    Text(subtitle, bundle: .module).susuType(.body).foregroundStyle(Palette.ink2)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
    }
}

/// A `bgGroup` block for rows (settings). Put `SettingsRow`s inside; hairlines between rows are automatic.
public struct GroupedRows<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        // Each row draws a hairline at its top; the first one is pushed out of the clip by -1 pt.
        VStack(spacing: 0) { content }
            .padding(.horizontal, 28)
            .padding(.top, -1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.bgGroup, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }
}

/// Settings row: label and description on the left, control on the right.
public struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?
    let control: Control
    public init(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, @ViewBuilder control: () -> Control) {
        self.title = title; self.detail = detail; self.control = control()
    }
    public var body: some View {
        HStack(spacing: Space.s6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title, bundle: .module).susuType(.bodyStrong).foregroundStyle(Palette.ink)
                if let detail {
                    Text(detail, bundle: .module).susuType(.body).foregroundStyle(Palette.ink2)
                }
            }
            Spacer(minLength: 0)
            control
        }
        .padding(.vertical, Space.s4)
        .frame(minHeight: 68)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

/// Group title above a `GroupedRows` block (sentence case, no eyebrow).
public struct GroupTitle: View {
    let text: LocalizedStringKey
    public init(_ text: LocalizedStringKey) { self.text = text }
    public var body: some View {
        Text(text, bundle: .module).susuType(.title2).foregroundStyle(Palette.ink).padding(.top, 28).padding(.bottom, 12)
    }
}

// MARK: - Tabs, chips, badges

public struct SusuTabItem<Value: Hashable>: Identifiable {
    public var id: Value { value }
    public let value: Value
    public let title: LocalizedStringKey
    public let symbol: String?
    public init(_ value: Value, _ title: LocalizedStringKey, symbol: String? = nil) {
        self.value = value; self.title = title; self.symbol = symbol
    }
}

/// Segmented pill tabs: a fill track, the selected tab is a white pill.
public struct SegmentedTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [SusuTabItem<Value>]
    let small: Bool
    @Namespace private var ns

    public init(selection: Binding<Value>, items: [SusuTabItem<Value>], small: Bool = false) {
        self._selection = selection; self.items = items; self.small = small
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let on = item.value == selection
                Button { selection = item.value } label: {
                    HStack(spacing: 8) {
                        if let s = item.symbol { Image(systemName: s).font(.system(size: 13)) }
                        Text(item.title, bundle: .module)
                    }
                    .susuType(small ? .small : .label)
                    .fontWeight(.medium)
                    .foregroundStyle(on ? Palette.ink : Palette.ink2)
                    .padding(.horizontal, small ? 12 : 16)
                    .frame(height: small ? 30 : 36)
                    .background {
                        if on {
                            Capsule().fill(Palette.bgCard).susuShadow(.card, radius: 18).matchedGeometryEffect(id: "pill", in: ns)
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

/// Filter chip: neutral fill, ink fill when on.
public struct FilterChip: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    @State private var hovering = false
    public init(_ title: LocalizedStringKey, isOn: Binding<Bool>) { self.title = title; self._isOn = isOn }
    public var body: some View {
        Button { isOn.toggle() } label: {
            Text(title, bundle: .module).susuType(.small).fontWeight(.medium)
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

/// Small label chip (tag).
public struct Tag: View {
    public enum Style: Sendable { case neutral, accent, call }
    let text: LocalizedStringKey
    let style: Style
    public init(_ text: LocalizedStringKey, style: Style = .neutral) { self.text = text; self.style = style }
    public var body: some View {
        Text(text, bundle: .module).susuType(.caption)
            .foregroundStyle(style == .accent ? Palette.accentInk : style == .call ? Palette.callInk : Palette.ink2)
            .padding(.horizontal, 8).frame(height: 22)
            .background(style == .accent ? Palette.accentSoft : style == .call ? Palette.callSoft : Palette.bgFill,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Status badge: dot + text. `.preparing` is a hollow dot.
public struct StatusBadge: View {
    public enum Kind: Sendable { case neutral, recording, preparing, ok, error }
    let text: LocalizedStringKey
    let kind: Kind
    public init(_ text: LocalizedStringKey, kind: Kind = .neutral) { self.text = text; self.kind = kind }
    private var tint: Color {
        switch kind {
        case .neutral, .preparing: Palette.ink3
        case .recording: Palette.call
        case .ok: Palette.ok
        case .error: Palette.error
        }
    }
    private var textColor: Color {
        switch kind {
        case .neutral, .preparing: Palette.ink2
        case .recording: Palette.callInk
        case .ok: Palette.ok
        case .error: Palette.error
        }
    }
    public var body: some View {
        HStack(spacing: 6) {
            Circle().strokeBorder(tint, lineWidth: kind == .preparing ? 1.5 : 0)
                .background(Circle().fill(kind == .preparing ? .clear : tint))
                .frame(width: 6, height: 6)
            Text(text, bundle: .module).susuType(.caption).foregroundStyle(textColor)
        }
    }
}

// MARK: - Search, empty state

/// Search field: magnifier, clear button, optional shortcut hint (e.g. "⌘F").
public struct SearchField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey
    let shortcutHint: String?
    @FocusState private var focused: Bool
    @State private var hovering = false

    public init(text: Binding<String>, prompt: LocalizedStringKey, shortcutHint: String? = nil) {
        self._text = text; self.prompt = prompt; self.shortcutHint = shortcutHint
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Palette.ink3)
            TextField("", text: $text, prompt: Text(prompt, bundle: .module).foregroundStyle(Palette.ink3))
                .textFieldStyle(.plain).susuType(.body).foregroundStyle(Palette.ink)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.bgCard)
                        .frame(width: 18, height: 18).background(Palette.ink3, in: Circle())
                }.buttonStyle(.plain)
            } else if let shortcutHint, !focused {
                Text(shortcutHint).susuType(.caption).foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 6).frame(height: 20)
                    .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Metrics.control)
        .background(focused ? Palette.bgCard : (hovering ? Palette.bgFill : Palette.bgGroup),
                    in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .strokeBorder(focused ? Palette.accent : .clear, lineWidth: 1))
        .onHover { hovering = $0 }
        .susuAnimation(Motion.fast, value: focused)
    }
}

/// Empty state: 32 icon, one sentence, at most one action.
public struct EmptyState: View {
    let symbol: String
    let text: LocalizedStringKey
    let actionTitle: LocalizedStringKey?
    let action: (() -> Void)?

    public init(symbol: String, text: LocalizedStringKey, actionTitle: LocalizedStringKey? = nil, action: (() -> Void)? = nil) {
        self.symbol = symbol; self.text = text; self.actionTitle = actionTitle; self.action = action
    }

    public var body: some View {
        VStack(spacing: Space.s3) {
            Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(Palette.ink3)
            Text(text, bundle: .module).susuType(.body).foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
            if let actionTitle, let action {
                Button(action: action) { Text(actionTitle, bundle: .module) }.buttonStyle(.susu(.neutral))
            }
        }
        .padding(Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar

/// Sidebar / settings-nav row: 40 high, SF Symbol 16, selected row on bgSelected.
public struct SidebarRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    public init(_ title: LocalizedStringKey, symbol: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.isSelected = isSelected; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 16, weight: .regular)).frame(width: 20)
                Text(title, bundle: .module).susuType(.label).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected || hovering ? Palette.ink : Palette.ink2)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(isSelected ? Palette.bgSelected : (hovering ? Palette.bgHover : .clear),
                        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .susuAnimation(Motion.fast, value: hovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Brand mark: two rounded bars (same glyph as the menu-bar icon).
public struct BrandMark: View {
    public init() {}
    public var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            Capsule().frame(width: 5, height: 16)
            Capsule().frame(width: 5, height: 13)
        }
        .padding(.bottom, 2)
        .frame(width: 24, height: 24, alignment: .bottom)
        .foregroundStyle(Palette.ink)
        .accessibilityHidden(true)
    }
}
