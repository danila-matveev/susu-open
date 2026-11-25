// Buttons and the switch. Sizes: small 28, regular 36, large 44 (tokens.css .btn).
import SwiftUI

public enum SusuButtonKind: Sendable {
    /// Neutral fill: «Изменить», secondary actions.
    case neutral
    /// Accent fill: the one main action of a screen.
    case primary
    /// Accent text on transparent: links and light actions.
    case plain
    /// Ink-2 text on transparent: toolbar-like actions.
    case quiet
    /// Brick-colored text. Pair with a confirm step.
    case destructive
}

public enum SusuControlSize: Sendable {
    case small, regular, large
    var height: CGFloat {
        switch self { case .small: Metrics.controlSmall; case .regular: Metrics.control; case .large: 44 }
    }
    var padding: CGFloat {
        switch self { case .small: 12; case .regular: 16; case .large: 24 }
    }
    var type: TypeStyle {
        switch self { case .small: .small; case .regular: .label; case .large: .body }
    }
}

public struct SusuButtonStyle: ButtonStyle {
    var kind: SusuButtonKind
    var size: SusuControlSize
    var fillWidth: Bool

    public func makeBody(configuration: Configuration) -> some View {
        SusuButtonBody(configuration: configuration, kind: kind, size: size, fillWidth: fillWidth)
    }
}

private struct SusuButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: SusuButtonKind
    let size: SusuControlSize
    let fillWidth: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .susuType(size.type)
            .fontWeight(kind == .primary ? .semibold : (size == .small ? .medium : nil))
            .foregroundStyle(foreground)
            .padding(.horizontal, size.padding)
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .frame(height: size.height)
            .background(background, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .strokeBorder(Palette.error, lineWidth: kind == .destructive && configuration.isPressed ? 1 : 0)
            )
            .opacity(enabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .onHover { hovering = $0 }
            .susuAnimation(Motion.fast, value: hovering)
            .susuAnimation(Motion.fast, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .neutral: Palette.ink
        case .primary: Palette.onAccent
        case .plain: Palette.accentInk
        case .quiet: hovering ? Palette.ink : Palette.ink2
        case .destructive: Palette.error
        }
    }

    private var background: Color {
        let pressed = configuration.isPressed
        switch kind {
        case .neutral: return pressed ? Palette.lineStrong : (hovering ? Palette.bgSelected : Palette.bgFill)
        case .primary: return pressed ? Palette.accent.opacity(0.74) : (hovering ? Palette.accent.opacity(0.86) : Palette.accent)
        case .plain: return hovering || pressed ? Palette.accentSoft : .clear
        case .quiet: return hovering || pressed ? Palette.bgHover : .clear
        case .destructive: return hovering || pressed ? Palette.errorSoft : .clear
        }
    }
}

extension ButtonStyle where Self == SusuButtonStyle {
    /// `Button("…") {}.buttonStyle(.susu(.primary))`
    public static func susu(_ kind: SusuButtonKind = .neutral, size: SusuControlSize = .regular, fillWidth: Bool = false) -> SusuButtonStyle {
        SusuButtonStyle(kind: kind, size: size, fillWidth: fillWidth)
    }
}

/// Round icon button: 40 white with a shadow (header actions), or 32 ghost (card actions).
public struct IconButton: View {
    public enum Style: Sendable { case round, ghost }
    let symbol: String
    let style: Style
    let help: LocalizedStringKey?
    let action: () -> Void
    @State private var hovering = false

    public init(_ symbol: String, style: Style = .ghost, help: LocalizedStringKey? = nil, action: @escaping () -> Void) {
        self.symbol = symbol; self.style = style; self.help = help; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(hovering ? Palette.ink : (style == .round ? Palette.ink2 : Palette.ink3))
                .frame(width: style == .round ? 40 : 32, height: style == .round ? 40 : 32)
                .background {
                    switch style {
                    case .round:
                        Circle().fill(hovering ? Palette.bgGroup : Palette.bgCard).susuShadow(.card, radius: 20)
                    case .ghost:
                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(hovering ? Palette.bgHover : .clear)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .susuAnimation(Motion.fast, value: hovering)
        .help(help.map { Text($0, bundle: .module) } ?? Text(verbatim: ""))
    }
}

/// Switch: 46×28, accent when on.
public struct SusuSwitchStyle: ToggleStyle {
    public func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Button { configuration.isOn.toggle() } label: {
                Capsule()
                    .fill(configuration.isOn ? Palette.accent : Palette.bgFill)
                    .frame(width: 46, height: 28)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(Palette.bgCard).frame(width: 22, height: 22).padding(3)
                            .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                    }
            }
            .buttonStyle(.plain)
            .susuAnimation(Motion.standard, value: configuration.isOn)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
        }
    }
}

extension ToggleStyle where Self == SusuSwitchStyle {
    public static var susu: SusuSwitchStyle { SusuSwitchStyle() }
}
