// Design tokens: type, spacing, radii, shadows, motion. Values from docs/design/prototype/tokens.css.
import SwiftUI

/// Type styles. `font` is the size/weight; `lineHeight` is applied through `.susuType(_:)`.
public enum TypeStyle: Sendable {
    case display, title, title2, body, bodyStrong, label, small, caption, number

    public var size: CGFloat {
        switch self {
        case .display: 30
        case .title: 22
        case .title2: 17
        case .body, .bodyStrong: 15
        case .label: 14
        case .small: 13
        case .caption: 12
        case .number: 34
        }
    }
    public var lineHeight: CGFloat {
        switch self {
        case .display: 36
        case .title: 28
        case .title2: 24
        case .body, .bodyStrong: 22
        case .label: 20
        case .small: 18
        case .caption: 16
        case .number: 38
        }
    }
    public var weight: Font.Weight {
        switch self {
        case .display, .title, .title2, .bodyStrong, .number: .semibold
        case .label, .caption: .medium
        case .body, .small: .regular
        }
    }
    public var font: Font {
        let f = Font.system(size: size, weight: weight)
        return self == .number ? f.monospacedDigit() : f
    }
    /// Extra spacing between lines so that the line box matches the CSS line-height.
    var lineSpacing: CGFloat { max(0, lineHeight - size * 1.2) }
}

extension View {
    /// Applies a type style (font and line height). Use `.monospacedDigit()` for timers and counters.
    public func susuType(_ style: TypeStyle) -> some View {
        font(style.font).lineSpacing(style.lineSpacing)
    }
}

/// 4-pt grid.
public enum Space {
    public static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16, s5: CGFloat = 20
    public static let s6: CGFloat = 24, s8: CGFloat = 32, s10: CGFloat = 40, s12: CGFloat = 48
}

public enum Radius {
    /// Buttons, inputs, chips.
    public static let sm: CGFloat = 8
    /// Rows, popovers.
    public static let md: CGFloat = 12
    /// Cards, groups.
    public static let lg: CGFloat = 16
    /// Windows, sheets, the content card.
    public static let xl: CGFloat = 20
    public static let pill: CGFloat = 999
}

/// Control sizes and window metrics.
public enum Metrics {
    public static let control: CGFloat = 36
    public static let controlSmall: CGFloat = 28
    public static let row: CGFloat = 56
    public static let sidebarWidth: CGFloat = 232
    public static let settingsNavWidth: CGFloat = 260
    public static let mainWindowSize = CGSize(width: 1200, height: 800)
    public static let mainWindowMinSize = CGSize(width: 900, height: 600)
    public static let settingsWindowSize = CGSize(width: 960, height: 640)
    public static let cardInset: CGFloat = 8
}

/// Motion. Reduce Motion is honored by `.susuAnimation(_:value:)`.
public enum Motion {
    /// 180 ms ease-out-quint: default UI transition.
    public static let standard = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)
    /// 120 ms: fast feedback (hover, press).
    public static let fast = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.12)
    /// 260 ms: panels and sheets.
    public static let slow = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.26)
    /// 220 ms with a small settle: pill size changes.
    public static let pill = Animation.timingCurve(0.34, 1.32, 0.64, 1, duration: 0.22)
}

private struct SusuAnimation<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `.animation` that turns off under Reduce Motion.
    public func susuAnimation<V: Equatable>(_ animation: Animation = Motion.standard, value: V) -> some View {
        modifier(SusuAnimation(animation: animation, value: value))
    }
}

/// Shadows from tokens.css: a 0.5 pt ring plus a soft drop.
public enum SusuShadow: Sendable { case card, pop, window }

private struct SusuShadowModifier: ViewModifier {
    let kind: SusuShadow
    let radius: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        switch kind {
        case .card:
            content
                .overlay(shape.strokeBorder(Palette.shadowRing, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
        case .pop:
            content
                .overlay(shape.strokeBorder(Palette.shadowRing, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 16, y: 12)
                .shadow(color: .black.opacity(0.06), radius: 3, y: 2)
        case .window:
            content
                .overlay(shape.strokeBorder(Palette.shadowRing, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 32, y: 24)
        }
    }
}

extension View {
    /// Card/popover/window shadow for a rounded rectangle of the given corner radius.
    public func susuShadow(_ kind: SusuShadow = .card, radius: CGFloat = Radius.lg) -> some View {
        modifier(SusuShadowModifier(kind: kind, radius: radius))
    }
}
