// Right side of «Стили»: four cards (basics, cleaning level, where to apply, try it).
import SwiftUI
import SusuCore

struct StyleEditor: View {
    @EnvironmentObject private var shell: ShellModel
    @ObservedObject var vm: StylesModel
    @State private var draft: Style
    @State private var showSaved = false
    @State private var addingRule = false
    @State private var confirmingDelete = false

    init(vm: StylesModel, style: Style) {
        self.vm = vm
        _draft = State(initialValue: style)
    }

    private var s: TableStrings { shell.strings("Styles") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(vm.displayName(draft, s)).susuType(.title).tracking(-0.2).foregroundStyle(Palette.ink).lineLimit(1)
                Spacer(minLength: 12)
                savedBadge
            }
            .padding(.horizontal, 4).padding(.bottom, 12).frame(minHeight: 40)

            ScrollView {
                CardArea {
                    basicsCard
                    levelCard
                    whereCard
                    PreviewCard(style: draft, rawKey: draft.id)
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: draft) { _, new in vm.edit(new) }
        .onChange(of: vm.savedTick) { _, _ in flashSaved() }
        .sheet(isPresented: $addingRule) {
            RuleSheet(vm: vm, style: draft)
        }
    }

    // MARK: Saved badge

    private var savedBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(Palette.ok).frame(width: 6, height: 6)
            Text(s("st.saved")).susuType(.caption).foregroundStyle(Palette.ok)
        }
        .opacity(showSaved ? 1 : 0)
        .susuAnimation(Motion.standard, value: showSaved)
    }

    private func flashSaved() {
        showSaved = true
        Task {
            try? await Task.sleep(for: .milliseconds(1600))
            showSaved = false
        }
    }

    // MARK: Basics

    private var nameBinding: Binding<String> {
        Binding(get: { vm.displayName(draft, s) }, set: { draft.name = $0 })
    }

    private var basicsCard: some View {
        TitledCard(s("st.main")) {
            VStack(alignment: .leading, spacing: 16) {
                Field(s("st.name")) { LineField(text: nameBinding) }
                Field(s("st.rule"), hint: s("st.rule.hint")) { AreaField(text: $draft.prompt) }
                VStack(spacing: 0) {
                    PlainRow(s("st.cmds"), detail: s("st.cmds.d"), first: true) {
                        Toggle("", isOn: $draft.voiceCommands).toggleStyle(.susu).labelsHidden()
                    }
                    PlainRow(s("st.default"), detail: s("st.default.d")) {
                        if draft.isDefault {
                            HStack(spacing: 6) {
                                Circle().fill(Palette.ok).frame(width: 6, height: 6)
                                Text(s("st.default.is")).susuType(.caption).foregroundStyle(Palette.ok)
                            }
                        } else {
                            Button(s("st.default.make")) { Task { await vm.makeDefault(draft.id); draft.isDefault = true } }
                                .buttonStyle(.susu(.neutral))
                        }
                    }
                    deleteRow
                }
                .padding(.horizontal, 20)
                .background(Palette.bgGroup, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            }
        }
    }

    @ViewBuilder private var deleteRow: some View {
        if draft.isDefault {
            PlainRow(s("st.del"), detail: s("st.del.fallback")) {
                Button(s("st.delete")) {}.buttonStyle(.susu(.destructive)).disabled(true)
            }
        } else if confirmingDelete {
            PlainRow(s.format("st.del.q", vm.displayName(draft, s),
                              vm.defaultStyle.map { vm.displayName($0, s) } ?? "")) {
                HStack(spacing: 8) {
                    Button(s("st.keep")) { confirmingDelete = false }.buttonStyle(.susu(.neutral))
                    Button(s("st.delete")) { Task { await vm.delete(draft.id) } }.buttonStyle(.susu(.destructive))
                }
            }
        } else {
            PlainRow(s("st.del"), detail: s("st.del.d")) {
                Button(s("st.delete")) { confirmingDelete = true }.buttonStyle(.susu(.destructive))
            }
        }
    }

    // MARK: Level

    private var levelCard: some View {
        TitledCard(s("st.levelCard")) {
            VStack(alignment: .leading, spacing: 12) {
                PillTabs(
                    selection: Binding(get: { draft.level }, set: { draft.cleanupLevel = $0.rawValue }),
                    items: CleanupLevel.allCases.map { ($0, s("st.level.\($0.rawValue)")) }, fill: true)
                Text(s("st.level.d.\(draft.level.rawValue)")).susuType(.small).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if draft.level == .verbatim {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle").font(.system(size: 13))
                        Text(s("st.model.note")).susuType(.small)
                    }
                    .foregroundStyle(Palette.ink3)
                }
            }
        }
    }

    // MARK: Where

    private var whereCard: some View {
        let rules = vm.rules(of: draft.id)
        return TitledCard(s("st.where")) {
            VStack(alignment: .leading, spacing: 12) {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    if draft.isDefault && rules.isEmpty {
                        Text(s("st.where.fallback")).susuType(.small).foregroundStyle(Palette.ink2)
                    } else if rules.isEmpty {
                        Text(s("st.where.none")).susuType(.small).foregroundStyle(Palette.ink2)
                    }
                    ForEach(rules) { rule in
                        RuleChip(rule: rule, removeHelp: s("st.where.remove"), titleHas: s("st.where.titleHas")) {
                            Task { await vm.removeRule(rule.id) }
                        }
                    }
                    Button { addingRule = true } label: {
                        HStack(spacing: 6) { Image(systemName: "plus").font(.system(size: 12, weight: .semibold)); Text(s("st.where.add")) }
                    }
                    .buttonStyle(.susu(.plain, size: .small))
                }
                Text(s("st.where.prio")).susuType(.small).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Rule chip

private struct RuleChip: View {
    let rule: StyleRule
    let removeHelp: String
    let titleHas: String
    let onRemove: () -> Void
    @State private var removeHover = false

    var body: some View {
        HStack(spacing: 8) {
            switch rule.kind {
            case "bundle":
                AppIconView(bundleId: rule.pattern, fallbackName: AppCatalog.installedName(rule.pattern) ?? rule.pattern)
                Text(AppCatalog.installedName(rule.pattern) ?? rule.pattern).susuType(.label).foregroundStyle(Palette.ink)
            case "url":
                Image(systemName: "globe").font(.system(size: 13)).foregroundStyle(Palette.ink3)
                Text(rule.pattern).font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.ink)
            default:
                Image(systemName: "macwindow").font(.system(size: 13)).foregroundStyle(Palette.ink3)
                Text(titleHas).susuType(.small).foregroundStyle(Palette.ink3)
                Text("«\(rule.pattern)»").susuType(.label).foregroundStyle(Palette.ink)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(removeHover ? Palette.ink : Palette.ink3)
                    .frame(width: 24, height: 24)
                    .background(removeHover ? Palette.bgFill : .clear, in: Circle())
            }
            .buttonStyle(.plain)
            .onHover { removeHover = $0 }
            .help(removeHelp)
            .accessibilityLabel(removeHelp)
        }
        .lineLimit(1)
        .padding(.leading, 6).padding(.trailing, 4)
        .frame(height: 32)
        .background(Palette.bgGroup, in: Capsule())
    }
}

// MARK: - Flow layout

/// Wraps children onto new lines when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                                           anchor: .topLeading, proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [(index: Int, size: CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, v) in subviews.enumerated() {
            var size = v.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            let needed = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].items.isEmpty { rows.append(Row()) }
            let last = rows.count - 1
            rows[last].width = rows[last].items.isEmpty ? size.width : rows[last].width + spacing + size.width
            rows[last].height = max(rows[last].height, size.height)
            rows[last].items.append((i, size))
        }
        return rows
    }
}

// MARK: - Preview card

private struct PreviewCard: View {
    @EnvironmentObject private var shell: ShellModel
    @Environment(\.stylePreviewing) private var hook
    let style: Style
    let rawKey: String

    private enum Phase: Equatable {
        case idle, loading
        case done(StylePreviewResult, ms: Int)
        case noKey
        case failed(String)
    }

    @State private var raw = ""
    @State private var phase: Phase = .idle
    @State private var task: Task<Void, Never>?

    private var s: TableStrings { shell.strings("Styles") }

    var body: some View {
        TitledCard(s("st.prev")) {
            VStack(alignment: .leading, spacing: 12) {
                Field(s("st.prev.raw")) { AreaField(text: $raw, minHeight: 64) }
                HStack(spacing: 12) {
                    Button(s("st.prev.show"), action: run).buttonStyle(.susu(.primary))
                        .disabled(phase == .loading || raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text(s("st.prev.showHint")).susuType(.small).foregroundStyle(Palette.ink2)
                }
                result
            }
        }
        .onAppear { if raw.isEmpty { raw = s("st.prev.sample") } }
        .onChange(of: style.cleanupLevel) { _, _ in reset() }
        .onChange(of: style.prompt) { _, _ in reset() }
        .onChange(of: style.voiceCommands) { _, _ in reset() }
        .onDisappear { task?.cancel() }
    }

    private func reset() { task?.cancel(); phase = .idle }

    private func run() {
        task?.cancel()
        phase = .loading
        let style = style, raw = raw
        let hook = hook, dictionary = shell.services.dictionary
        task = Task {
            let started = ContinuousClock.now
            do {
                let result: StylePreviewResult
                if let hook { result = try await hook(raw, style) } else {
                    result = try await StylePreview.rulesOnly(raw: raw, style: style, dictionary: dictionary)
                }
                let d = ContinuousClock.now - started
                let ms = Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
                guard !Task.isCancelled else { return }
                phase = .done(result, ms: ms)
            } catch StylePreviewError.noEditorKey {
                guard !Task.isCancelled else { return }
                phase = .noKey
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder private var result: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .loading:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(s("st.prev.busy")).susuType(.bodyStrong).foregroundStyle(Palette.ink) }
                skeleton(0.92); skeleton(0.58)
            }
            .outputBox()
        case .noKey:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 14))
                    Text(s("st.prev.noKey")).susuType(.small)
                    Spacer(minLength: 0)
                    Button(s("st.prev.addKey")) { shell.openSettings(.keys) }.buttonStyle(.susu(.plain, size: .small))
                }
                .foregroundStyle(Palette.error)
            }
            .outputBox(error: true)
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 14))
                Text(s.format("st.prev.failed", message)).susuType(.small)
            }
            .foregroundStyle(Palette.error).outputBox(error: true)
        case .done(let r, let ms):
            VStack(alignment: .leading, spacing: 8) {
                if !r.usedEditor && style.level != .verbatim && hook == nil {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle").font(.system(size: 13))
                        Text(s("st.prev.notConnected")).susuType(.small)
                    }
                    .foregroundStyle(Palette.ink3)
                }
                Text(s("st.prev.after")).susuType(.small).foregroundStyle(Palette.ink3)
                Text(r.text).susuType(.body).foregroundStyle(Palette.ink).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta(r, ms: ms)).susuType(.caption).foregroundStyle(Palette.ink3)
            }
            .outputBox()
        }
    }

    private func meta(_ r: StylePreviewResult, ms: Int) -> String {
        var text: String
        if r.usedEditor {
            let sec = String(format: "%.2f", Double(ms) / 1000)
            text = s.format("st.prev.metaEditor", r.editorLabel ?? "", sec)
        } else if style.level == .verbatim {
            text = s.format("st.prev.metaNoModel", max(1, ms))
        } else {
            text = s.format("st.prev.metaRules", max(1, ms))
        }
        if r.pressEnter { text += s("st.prev.metaEnter") }
        return text
    }

    private func skeleton(_ fraction: CGFloat) -> some View {
        GeometryReader { g in
            RoundedRectangle(cornerRadius: 4).fill(Palette.bgFill).frame(width: g.size.width * fraction, height: 12)
        }
        .frame(height: 12)
    }
}

private extension View {
    func outputBox(error: Bool = false) -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.bgGroup, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Palette.error, lineWidth: error ? 1 : 0))
            .padding(.top, 2)
    }
}
