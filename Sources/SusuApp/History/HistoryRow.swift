// One feed row: dictation, agent request (and call, when call records exist).
import SwiftUI
import SusuCore

struct HistoryRow: View {
    let d: Dictation
    let showsSeparator: Bool
    let compact: Bool
    @ObservedObject var model: HistoryModel
    @State private var hovering = false

    private var isSelected: Bool { model.selectedID == d.id }
    private var isPlaying: Bool { model.playingID == d.id }
    private var keepActions: Bool { d.needsAttention || isSelected }

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 12 : 16) {
            meta.frame(width: compact ? 88 : 140, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                content
                if isPlaying { playBar.padding(.top, 8) }
                sub
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions.opacity(hovering || keepActions ? 1 : 0)
        }
        .padding(12)
        .background(isSelected ? Palette.accentSoft : (hovering ? Palette.bgGroup : .clear),
                    in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(alignment: .top) {
            if showsSeparator && !hovering && !isSelected { Rectangle().fill(Palette.line).frame(height: 1) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(d) }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(d.appLabel), \(HL.time(d.createdAt))"))
    }

    // MARK: columns

    private var tone: HistoryAppIcon.Tone { d.kind == .agent ? .agent : .plain }

    private var meta: some View {
        HStack(spacing: 8) {
            Text(verbatim: HL.time(d.createdAt, calendar: model.calendar))
                .susuType(.small).monospacedDigit().foregroundStyle(Palette.ink2).fixedSize()
            HistoryAppIcon(name: d.appLabel, tone: tone)
            if !compact {
                Text(verbatim: d.appLabel).susuType(.small).foregroundStyle(Palette.ink3).lineLimit(1)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder private var content: some View {
        if d.kind == .agent { agentContent } else { dictationContent }
    }

    private var dictationContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if d.hasText {
                Text(Highlight.attributed(d.displayText, query: model.query))
                    .susuType(.body).foregroundStyle(Palette.ink).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.rawShown.contains(d.id), let raw = d.rawText, !raw.isEmpty {
                    Text(verbatim: raw).font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.ink2)
                        .textSelection(.enabled)
                }
            } else {
                HText(d.status == .cancelled ? "hist.cancelled.text" : "hist.failed.text")
                    .susuType(.body).foregroundStyle(Palette.ink3)
            }
        }
    }

    private var agentContent: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 2) {
            agentLine("hist.a.said", d.rawText)
            agentLine("hist.a.took", d.windowTitle)
            agentLine("hist.a.did", d.finalText)
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    @ViewBuilder private func agentLine(_ label: LocalizedStringKey, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow(alignment: .top) {
                HText(label).susuType(.small).foregroundStyle(Palette.ink3).padding(.top, 2)
                Text(Highlight.attributed(value, query: model.query)).susuType(.body).foregroundStyle(Palette.ink)
                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var playBar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.bgFill)
                Capsule().fill(Palette.accent).frame(width: g.size.width * model.progress)
            }
        }
        .frame(height: 3)
    }

    // MARK: status line

    @ViewBuilder private var sub: some View {
        let lang = model.language
        let pasteKey = HL.hotkey(model.services.settings.current.hotkeys.pasteLast, lang)
        if d.kind == .agent {
            HStack(spacing: 12) {
                HistoryTag("hist.badge.agent", style: .accent)
                if let url = d.url, let link = URL(string: url) {
                    Button { NSWorkspace.shared.open(link) } label: {
                        HStack(spacing: 4) {
                            Text(verbatim: linkTitle(url)).susuType(.small).fontWeight(.semibold).lineLimit(1)
                            Image(systemName: "arrow.up.right.square").font(.system(size: 12))
                        }.foregroundStyle(Palette.accentInk)
                    }.buttonStyle(.plain)
                }
                if model.actions.canUndoAgent(d) {
                    Button { model.undoAgent(d) } label: { HText("hist.undo") }.buttonStyle(.susu(.neutral, size: .small))
                }
            }
            .padding(.top, 8)
        } else if model.retrying.contains(d.id) {
            subRow {
                ProgressView().controlSize(.small)
                HText("hist.recognizing").susuType(.small).foregroundStyle(Palette.ink2)
            }
        } else {
            switch d.status {
            case .notInserted:
                subRow {
                    HistoryBadge("hist.badge.notPasted", kind: .error)
                    Text(verbatim: HL.string("hist.np.hint", lang, pasteKey)).susuType(.caption).foregroundStyle(Palette.ink3)
                    retryButton("hist.retry")
                }
            case .copiedOnly:
                subRow {
                    HistoryBadge("hist.badge.copied", kind: .neutral)
                    HText("hist.copied.hint").susuType(.caption).foregroundStyle(Palette.ink3)
                    retryButton("hist.retry")
                }
            case .failed:
                subRow {
                    HistoryBadge("hist.badge.failed", kind: .error)
                    retryButton("hist.retry")
                }
            case .cancelled:
                subRow {
                    HistoryBadge("hist.badge.cancelled", kind: .preparing)
                    if model.audioAvailable(d) {
                        Button { model.togglePlay(d) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isPlaying && model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 10))
                                HText(isPlaying && model.isPlaying ? "hist.pause" : "hist.listen")
                            }
                        }.buttonStyle(.susu(.neutral, size: .small))
                    }
                    retryButton("hist.recognize")
                }
            default:
                if d.fallbackUsed {
                    subRow {
                        HistoryBadge("hist.badge.fallback", kind: .neutral)
                        HText("hist.fb.hint").susuType(.caption).foregroundStyle(Palette.ink3)
                    }
                }
            }
        }
    }

    private func subRow<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HistoryFlow(spacing: 12) { c() }.padding(.top, 8).frame(minHeight: 22)
    }

    private func retryButton(_ title: LocalizedStringKey) -> some View {
        Button { model.retry(d) } label: { HText(title) }.buttonStyle(.susu(.neutral, size: .small))
    }

    private func linkTitle(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }

    // MARK: hover actions

    private var actions: some View {
        HStack(spacing: 2) {
            if d.kind == .dictation {
                HistoryIconButton(symbol: "doc.on.doc", help: "hist.act.copy", isEnabled: d.hasText) { model.copy(d) }
                HistoryIconButton(
                    symbol: isPlaying && model.isPlaying ? "pause" : "play",
                    help: isPlaying && model.isPlaying ? "hist.pause" : "hist.act.play",
                    disabledHelp: "hist.audio.gone", isEnabled: model.audioAvailable(d)
                ) { model.togglePlay(d) }
                HistoryIconButton(symbol: "return", help: "hist.act.again", isEnabled: d.hasText) { model.pasteAgain(d) }
            } else {
                HistoryIconButton(symbol: "doc.on.doc", help: "hist.act.copy", isEnabled: !(d.finalText ?? "").isEmpty) {
                    model.copy(d)
                }
            }
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            if d.kind == .dictation {
                Menu {
                    Button { model.redo(d) } label: { HText("hist.m.redo") }
                    Button { model.openCompare(d) } label: { HText("hist.m.redoModel") }
                    Button { model.openCompare(d, style: true) } label: { HText("hist.m.redoStyle") }
                } label: { HText("hist.m.redo") }
                .disabled(!d.hasText)
                Divider()
                Button { model.saveAudio(d) } label: { HText("hist.m.download") }
                    .disabled(!model.audioAvailable(d))
                Button { model.toggleRaw(d) } label: {
                    HText(model.rawShown.contains(d.id) ? "hist.m.rawHide" : "hist.m.raw")
                }
                .disabled((d.rawText ?? "").isEmpty)
            } else {
                Button { model.selectedID = d.id } label: { HText("hist.m.card") }
            }
            Divider()
            Button(role: .destructive) { model.delete(d) } label: { HText("hist.m.delete") }
        } label: {
            HistoryIconLabel(symbol: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(HText("hist.act.more"))
    }
}
