// SwiftUI content of the pill. Colors are the HUD tokens (dark in both themes); sizes come from PillMetrics.
import SwiftUI
import SusuCore

@MainActor
final class PillModel: ObservableObject {
    @Published var state: PillState = .idle
    @Published var hovered = false
    @Published var callDot = false
    /// A toast (or another surface) sits above the pill: the hint bubble steps aside.
    @Published var hasSlot = false
    @Published var language: InterfaceLanguage = .system
    @Published var hintOverride: String?
    /// Glyph of the configured dictation key, shown in the hands-free hint.
    @Published var keyName = "⌃"
    let sampler = WaveSampler()

    var onCancel: () -> Void = {}
    var onDone: () -> Void = {}
    var onCallClick: () -> Void = {}
    var onDragChanged: () -> Void = {}
    var onDragEnded: () -> Void = {}

    var display: PillState { state == .idle && hovered ? .hover : state }
}

/// Pill tokens: the agent accent and the brick are the prototype's `--x-ag` and `--error`.
private enum PillColor {
    static let agent = Color(light: 0x96AAC8, dark: 0xC1D7F3)
    static let hairline = Palette.hudLine
}

struct PillView: View {
    @ObservedObject var model: PillModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let d = model.display
        let size = PillMetrics.size(for: d, callDot: model.callDot)
        VStack(spacing: PillMetrics.hintGap) {
            hint(d)
            capsule(d, size)
        }
        .padding(.bottom, PillMetrics.bottomInset)
        .frame(width: PillMetrics.panelSize.width, height: PillMetrics.panelSize.height, alignment: .bottom)
        .animation(reduceMotion ? nil : Motion.pill, value: size)
        .animation(Motion.fast, value: d)
    }

    // MARK: capsule

    private func capsule(_ d: PillState, _ size: CGSize) -> some View {
        let agent = d.isAgent
        let stroke: Color = d == .error ? Palette.error : (agent ? PillColor.agent : PillColor.hairline)
        let inkColor: Color = agent ? PillColor.agent : Palette.hudInk
        let call = model.callDot
        return ZStack {
            Capsule().fill(Palette.hud)
            Capsule().strokeBorder(stroke, lineWidth: 1)
            layers(d, size: size, ink: inkColor)
            if call && d != .idle { callDotOutside(size) }
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(0.12), radius: 16, y: 12)
        .shadow(color: .black.opacity(0.06), radius: 3, y: 2)
        .opacity(d == .idle ? 0.6 : 1)
        .contentShape(Capsule())
        .gesture(DragGesture(minimumDistance: 4)
            .onChanged { _ in model.onDragChanged() }
            .onEnded { _ in model.onDragEnded() })
        .simultaneousGesture(TapGesture().onEnded {
            if model.callDot && (model.state == .idle) { model.onCallClick() }
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PillL10n.string(ariaKey(d), model.language))
    }

    @ViewBuilder private func layers(_ d: PillState, size: CGSize, ink: Color) -> some View {
        let waveVisible: Bool = d.isListeningLike || d == .processing
        let pending: Bool = { if case .listening(let ok) = d { return !ok } else { return false } }()
        let waveOpacity: Double = d == .processing ? 0.3 : (pending ? 0.4 : 1)
        // Mic (hover)
        Image(systemName: "mic").font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.hudInk).opacity(d == .hover ? 1 : 0)
        // Wave
        WaveView(model: model, height: d == .handsFree ? 22 : 14, frozen: d == .processing, color: ink)
            .opacity(waveVisible ? waveOpacity : 0)
            .offset(x: d == .noteListening ? 10 : 0)
        // Processing dots
        ProcessingDots(color: d.isAgent ? PillColor.agent : Palette.hudInk)
            .opacity(d == .processing || d == .agentWorking ? 1 : 0)
        // Error
        Image(systemName: "exclamationmark.triangle").font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.error).opacity(d == .error ? 1 : 0)
        // Agent waiting mark
        Image(systemName: "waveform").font(.system(size: 13, weight: .medium))
            .foregroundStyle(PillColor.agent).opacity(d == .agentWaiting ? 1 : 0)
        // Note glyph
        Image(systemName: "doc.text").font(.system(size: 12, weight: .medium))
            .foregroundStyle(Palette.hudInk)
            .offset(x: -size.width / 2 + 21).opacity(d == .noteListening ? 1 : 0)
        // Hands-free buttons
        HandsFreeButtons(model: model).opacity(d == .handsFree ? 1 : 0).allowsHitTesting(d == .handsFree)
        // Call indicator inside the thin capsule
        if model.callDot {
            HStack(spacing: 0) {
                Circle().fill(Palette.call).frame(width: 8, height: 8)
                Spacer(minLength: 0)
                Capsule().fill(Palette.hudInk2).frame(width: 30, height: 4)
            }
            .padding(.horizontal, 6)
            .opacity(d == .idle ? 1 : 0)
        }
    }

    private func callDotOutside(_ size: CGSize) -> some View {
        Circle().fill(Palette.call).frame(width: 6, height: 6).offset(x: -size.width / 2 - 14)
    }

    // MARK: hint

    private func hint(_ d: PillState) -> some View {
        let visible = d == .handsFree && !model.hasSlot
        let text = model.hintOverride ?? PillL10n.format("pill.hint", model.language, model.keyName)
        return Text(text)
            .susuType(.small)
            .foregroundStyle(Palette.hudInk)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: PillMetrics.hintHeight)
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Palette.hud))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Palette.hudLine, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 16, y: 12)
            .shadow(color: .black.opacity(0.06), radius: 3, y: 2)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
    }

    private func ariaKey(_ d: PillState) -> String {
        switch d {
        case .idle, .hover: "pill.aria.idle"
        case .listening: "pill.aria.listening"
        case .handsFree: "pill.aria.handsFree"
        case .processing: "pill.aria.processing"
        case .agentListening: "pill.aria.agent"
        case .agentWorking: "pill.aria.agentWorking"
        case .agentWaiting: "pill.aria.agentWaiting"
        case .noteListening: "pill.aria.note"
        case .error: "pill.aria.error"
        }
    }
}

// MARK: wave

private struct WaveView: View {
    @ObservedObject var model: PillModel
    let height: CGFloat
    let frozen: Bool
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            WaveCanvas(scales: scales(at: timeline.date), color: color)
        }
        .frame(width: 46, height: height)
    }

    private func scales(at date: Date) -> [Double] {
        if frozen { return Array(repeating: 0.3, count: 10) }
        let level = model.sampler.advance(now: ProcessInfo.processInfo.systemUptime)
        return WaveSampler.scales(level: level, time: date.timeIntervalSinceReferenceDate, breathing: !reduceMotion)
    }
}

private struct WaveCanvas: View {
    let scales: [Double]
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            for i in 0..<10 {
                let h = max(3, size.height * scales[i])
                let rect = CGRect(x: CGFloat(i) * 4.8, y: (size.height - h) / 2, width: 2.4, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.2), with: .color(color))
            }
        }
    }
}

private struct ProcessingDots: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(color).frame(width: 5, height: 5)
                        .opacity(reduceMotion ? 0.7 : Self.shimmer(t - Double(i) * 0.15))
                }
            }
        }
    }

    /// 1.1 s loop: .3 -> 1 at 40% -> .3 (keyframes `shimmer`, ease-in-out).
    static func shimmer(_ t: Double) -> Double {
        let p = (t / 1.1).truncatingRemainder(dividingBy: 1)
        let q = p < 0 ? p + 1 : p
        let e: Double = q < 0.4 ? q / 0.4 : 1 - (q - 0.4) / 0.6
        let s = e * e * (3 - 2 * e)
        return 0.3 + 0.7 * s
    }
}

// MARK: hands-free buttons

private struct HandsFreeButtons: View {
    @ObservedObject var model: PillModel
    @State private var xHover = false
    @State private var okHover = false

    var body: some View {
        HStack {
            Button(action: model.onCancel) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(xHover ? Palette.hudInk : Palette.hudInk2)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(xHover ? Palette.hudLine : .clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { xHover = $0 }
            .help(PillL10n.string("pill.cancel", model.language))
            .accessibilityLabel(PillL10n.string("pill.cancel", model.language))
            Spacer(minLength: 0)
            Button(action: model.onDone) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.hud)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Palette.hudInk.opacity(okHover ? 0.85 : 1)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { okHover = $0 }
            .help(PillL10n.string("pill.done", model.language))
            .accessibilityLabel(PillL10n.string("pill.done", model.language))
        }
        .padding(.horizontal, 8)
    }
}
