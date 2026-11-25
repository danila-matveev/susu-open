// Record card: the panel on the right (S-HISTCARD).
import SwiftUI
import SusuCore

struct HistoryCardPanel: View {
    let d: Dictation
    @ObservedObject var model: HistoryModel
    @State private var tab: Tab = .final

    enum Tab: Hashable { case raw, final, edited }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                mainCard
                detailsCard
            }
            .padding(12)
        }
        .frame(width: 392)
        .background(Palette.bgGroup, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .padding(.trailing, 12).padding(.bottom, 12)
        .onChange(of: d.id) { _, _ in tab = .final }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(HText("hist.card.title"))
    }

    private var lang: InterfaceLanguage { model.language }
    private var playing: Bool { model.playingID == d.id }

    // MARK: main card

    private var mainCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                HistoryAppIcon(name: d.appLabel, tone: d.kind == .agent ? .agent : .plain)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: d.appLabel).susuType(.bodyStrong).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(verbatim: [HL.dayShort(d.createdAt, calendar: model.calendar, lang), d.windowTitle]
                        .compactMap { $0 }.joined(separator: " · "))
                        .susuType(.caption).foregroundStyle(Palette.ink3).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { model.selectedID = nil } label: { HistoryIconLabel(symbol: "xmark") }
                    .buttonStyle(.plain).help(HText("hist.card.close"))
            }

            if d.kind == .agent { agentBody } else { dictationBody }

            HistoryFlow(spacing: 8) { cardActions }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .susuShadow(.card, radius: Radius.lg)
    }

    private var dictationBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            tabs
            Group {
                if !d.hasText {
                    HText(d.status == .cancelled ? "hist.cancelled.text" : "hist.failed.text").foregroundStyle(Palette.ink3)
                } else {
                    switch tab {
                    case .raw:
                        Text(verbatim: d.rawText ?? "").font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.ink2)
                    case .final:
                        Text(verbatim: (d.finalText?.isEmpty == false ? d.finalText : d.rawText) ?? "").foregroundStyle(Palette.ink)
                    case .edited:
                        if let e = d.editedText, !e.isEmpty { Text(verbatim: e).foregroundStyle(Palette.ink) }
                        else { HText("hist.noEdits").foregroundStyle(Palette.ink3) }
                    }
                }
            }
            .susuType(.body).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            player
        }
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            tabButton(.raw, "hist.tab.raw")
            tabButton(.final, "hist.tab.final")
            tabButton(.edited, "hist.tab.edited")
        }
        .padding(4)
        .background(Palette.bgFill, in: Capsule())
    }

    private func tabButton(_ t: Tab, _ title: LocalizedStringKey) -> some View {
        let on = tab == t
        return Button { tab = t } label: {
            HText(title).susuType(.small).fontWeight(.medium).lineLimit(1).minimumScaleFactor(0.85)
                .foregroundStyle(on ? Palette.ink : Palette.ink2)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background { if on { Capsule().fill(Palette.bgCard).susuShadow(.card, radius: 15) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private var player: some View {
        if model.audioAvailable(d) {
            HStack(spacing: 12) {
                Button { model.togglePlay(d) } label: {
                    Image(systemName: playing && model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12)).foregroundStyle(Palette.onAccent)
                        .frame(width: 32, height: 32).background(Palette.accent, in: Circle())
                }
                .buttonStyle(.plain).help(HText(playing && model.isPlaying ? "hist.pause" : "hist.act.play"))
                let total = playing ? model.playDuration : Double(d.durationMs ?? 0) / 1000
                Text(verbatim: HL.clock(playing ? model.progress * total : 0))
                    .susuType(.caption).monospacedDigit().foregroundStyle(Palette.ink2)
                HistoryScrubber(value: playing ? model.progress : 0) { model.seek($0, d) }
                Text(verbatim: HL.clock(total)).susuType(.caption).monospacedDigit().foregroundStyle(Palette.ink2)
            }
            .padding(.leading, 6).padding(.trailing, 16).frame(height: 44)
            .background(Palette.bgGroup, in: Capsule())
        } else {
            HText("hist.audio.gone.note").susuType(.small).foregroundStyle(Palette.ink2)
                .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.bgGroup, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
    }

    private var agentBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            detailLine("hist.a.said", d.rawText)
            detailLine("hist.a.took2", d.windowTitle)
            detailLine("hist.a.did", d.finalText)
            if let url = d.url { detailLine("hist.a.link", url) }
        }
    }

    @ViewBuilder private func detailLine(_ label: LocalizedStringKey, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HText(label).susuType(.small).foregroundStyle(Palette.ink3)
                Text(verbatim: value).susuType(.body).foregroundStyle(Palette.ink).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var cardActions: some View {
        if d.kind == .dictation {
            if d.needsAttention {
                Button { model.retry(d) } label: {
                    HStack(spacing: 6) { Image(systemName: "arrow.clockwise").font(.system(size: 12)); HText(d.status == .cancelled ? "hist.recognize" : "hist.retry") }
                }.buttonStyle(.susu(.primary, size: .small))
            }
            if d.hasText {
                actionButton("doc.on.doc", "hist.act.copy") { model.copy(d) }
                actionButton("return", "hist.act.again") { model.pasteAgain(d) }
            }
            Button { model.redo(d) } label: { HText("hist.m.redo") }
                .buttonStyle(.susu(.neutral, size: .small)).disabled(!d.hasText)
            actionButton("rectangle.split.2x1", "hist.m.redoModel") { model.openCompare(d) }.disabled(!d.hasText)
            Button { model.saveAudio(d) } label: {
                HStack(spacing: 6) { Image(systemName: "arrow.down.to.line").font(.system(size: 12)); HText("hist.m.download") }
            }.buttonStyle(.susu(.quiet, size: .small)).disabled(!model.audioAvailable(d))
        } else {
            if model.actions.canUndoAgent(d) {
                Button { model.undoAgent(d) } label: { HText("hist.undo") }.buttonStyle(.susu(.neutral, size: .small))
            }
        }
        Button { model.delete(d) } label: {
            HStack(spacing: 6) { Image(systemName: "trash").font(.system(size: 12)); HText("hist.m.delete") }
        }.buttonStyle(.susu(.destructive, size: .small))
    }

    private func actionButton(_ symbol: String, _ title: LocalizedStringKey, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { Image(systemName: symbol).font(.system(size: 12)); HText(title) }
        }.buttonStyle(.susu(.neutral, size: .small))
    }

    // MARK: details

    private func detailRows() -> [(LocalizedStringKey, String)] {
        let window: String = d.windowTitle ?? "—"
        var rows: [(LocalizedStringKey, String)] = []
        if d.kind == .dictation {
            let style: String = d.styleId.flatMap { model.styleNames[$0] } ?? "—"
            let provider: String = [d.sttProvider, d.sttModel].compactMap { $0 }.joined(separator: " · ").nonEmptyOrDash
            let editor: String = d.editorModel ?? HL.string("hist.d.editor.none", lang)
            let fallback: String = HL.string(d.fallbackUsed ? "hist.d.fallback.yes" : "hist.d.no", lang)
            var latency = "—"
            if let ms = d.latencyMs {
                latency = ms.formatted(.number.locale(HL.locale(lang))) + " " + HL.string("hist.ms", lang)
            }
            rows = [("hist.d.style", style), ("hist.d.provider", provider), ("hist.d.editor", editor),
                    ("hist.d.fallback", fallback), ("hist.d.latency", latency), ("hist.d.cost", HL.cost(d.costUsd)),
                    ("hist.d.app", d.appLabel), ("hist.d.window", window), ("hist.d.url", d.url ?? "—")]
        } else {
            rows = [("hist.d.app", d.appLabel), ("hist.d.window", window),
                    ("hist.d.time", HL.dayShort(d.createdAt, calendar: model.calendar, lang))]
        }
        return rows
    }

    private var detailsCard: some View {
        let rows = detailRows()
        return Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                GridRow(alignment: .top) {
                    HText(r.0).susuType(.small).foregroundStyle(Palette.ink3).frame(width: 112, alignment: .leading)
                    Text(verbatim: r.1).susuType(.small).foregroundStyle(Palette.ink).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .susuShadow(.card, radius: Radius.lg)
    }
}

private extension String {
    var nonEmptyOrDash: String { isEmpty ? "—" : self }
}

/// Thin audio position bar: tap or drag to seek.
struct HistoryScrubber: View {
    let value: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.bgFill).frame(height: 4)
                Capsule().fill(Palette.accent).frame(width: g.size.width * value, height: 4)
                Circle().fill(Palette.accent).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Palette.bgGroup, lineWidth: 3).frame(width: 18, height: 18))
                    .offset(x: g.size.width * value - 6)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { onSeek(min(1, max(0, $0.location.x / max(1, g.size.width)))) })
        }
        .frame(height: 20)
        .accessibilityElement()
        .accessibilityLabel(HText("hist.position"))
        .accessibilityValue(Text(verbatim: "\(Int(value * 100))%"))
    }
}
