// HUD card: icon + text + up to two buttons (components.css `.toast`). Dark in both themes.
import SwiftUI

@MainActor
final class ToastModel: ObservableObject {
    @Published var toast: Toast?
    @Published var serial = 0
    @Published var visible = false
    var onAction: (ToastAction) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }
}

enum ToastMetrics {
    // Prototype: `.x-slot > .toast { width: 340px }`, padding 14/16, radius var(--r-lg).
    static let width: CGFloat = 340
    static let radius: CGFloat = Radius.lg
    static let gapAbovePill: CGFloat = 12
    static let sidePad: CGFloat = 24
    static let topPad: CGFloat = 16
    static let bottomPad: CGFloat = 36
}

struct ToastView: View {
    @ObservedObject var model: ToastModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let toast = model.toast, model.visible {
                card(toast)
                    .id(model.serial)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
            }
        }
        .padding(.horizontal, ToastMetrics.sidePad)
        .padding(.top, ToastMetrics.topPad)
        .padding(.bottom, ToastMetrics.bottomPad)
        .animation(Motion.standard, value: model.serial)
        .animation(Motion.fast, value: model.visible)
        .onHover { model.onHover($0) }
    }

    private func card(_ t: Toast) -> some View {
        let shape = RoundedRectangle(cornerRadius: ToastMetrics.radius, style: .continuous)
        let iconColor: Color = t.kind == .error ? Palette.error : (t.kind == .success ? Palette.ok : Palette.hudInk)
        let ring: Color = t.kind == .error ? Palette.error : Palette.hudLine
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: t.resolvedIcon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 18, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(t.text).susuType(.bodyStrong).foregroundStyle(Palette.hudInk)
                    .fixedSize(horizontal: false, vertical: true)
                if let d = t.detail {
                    Text(d).susuType(.small).foregroundStyle(Palette.hudInk2).padding(.top, 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let link = t.link {
                    Button { model.onAction(link) } label: {
                        Text(link.title).susuType(.small).fontWeight(.medium).underline().foregroundStyle(Palette.hudInk)
                    }
                    .buttonStyle(.plain).padding(.top, 2)
                }
                if !t.actions.isEmpty {
                    ToastFlow(spacing: 6) {
                        ForEach(Array(t.actions.enumerated()), id: \.offset) { _, a in
                            Button(a.title) { model.onAction(a) }.buttonStyle(HUDButtonStyle(primary: a.isPrimary))
                        }
                    }
                    .padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14).padding(.horizontal, 16)
        .frame(width: ToastMetrics.width)
        .background(shape.fill(Palette.hud))
        .overlay(shape.strokeBorder(ring, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 12)
        .shadow(color: .black.opacity(0.06), radius: 3, y: 2)
        .accessibilityElement(children: .contain)
    }
}

/// `.btn--hud .btn--sm`: 28 high, radius 8, small medium text. Primary is light on dark.
struct HUDButtonStyle: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        HUDButtonBody(configuration: configuration, primary: primary)
    }
}

private struct HUDButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let primary: Bool
    @State private var hover = false
    var body: some View {
        configuration.label
            .susuType(.small).fontWeight(.medium)
            .foregroundStyle(primary ? Palette.hud : Palette.hudInk)
            .padding(.horizontal, 12).frame(height: Metrics.controlSmall)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(fill))
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .onHover { hover = $0 }
    }
    private var fill: Color {
        if primary { return Palette.hudInk.opacity(hover ? 0.85 : 1) }
        return hover ? Palette.hudInk.opacity(0.24) : Palette.hudLine
    }
}

/// Minimal wrapping row for the buttons.
struct ToastFlow: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(bounds.width, subviews)
        for (i, p) in r.origins.enumerated() { subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified) }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        var origins: [CGPoint] = []
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += s.width + spacing; rowH = max(rowH, s.height); maxW = max(maxW, x - spacing)
        }
        return (CGSize(width: maxW, height: y + rowH), origins)
    }
}
