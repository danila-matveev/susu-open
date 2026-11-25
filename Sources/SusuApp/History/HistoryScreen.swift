// «Главная / История» (spec 1.6, S-HIST). Plug into SectionRouter: `case .history: HistoryScreen()`.
import SwiftUI
import SusuCore

public struct HistoryScreen: View {
    @EnvironmentObject private var shell: ShellModel

    public init() {}

    public var body: some View {
        HistoryContent(services: shell.services)
    }
}

struct HistoryContent: View {
    @EnvironmentObject private var shell: ShellModel
    @Environment(\.historyActions) private var actions
    @StateObject private var model: HistoryModel
    @FocusState private var searchFocused: Bool

    init(services: AppServices) {
        _model = StateObject(wrappedValue: HistoryModel(services: services))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showChrome { toolbar }
            HStack(alignment: .top, spacing: 0) {
                feed
                if let d = model.selected {
                    HistoryCardPanel(d: d, model: model)
                        .padding(.top, 8)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .susuAnimation(Motion.slow, value: model.selectedID)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                HistoryToastView(toast: t) { model.dismissToast() }
                    .padding(.bottom, 20)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .susuAnimation(Motion.standard, value: model.toast)
        .overlay {
            if let c = model.compare {
                ZStack {
                    Palette.hud.opacity(0.3).ignoresSafeArea().onTapGesture { model.keepOriginal() }
                    HistoryCompareSheet(state: c, model: model)
                }
                .transition(.opacity)
            }
        }
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).opacity(0).frame(width: 0, height: 0)
        }
        .onExitCommand {
            if model.compare != nil { model.keepOriginal() }
            else if model.selectedID != nil { model.selectedID = nil }
        }
        .onAppear { sync() }
        .onChange(of: shell.language) { _, _ in sync() }
        .task { await model.run() }
        .onDisappear { model.flushPendingDeletes() }
    }

    private func sync() {
        model.actions = actions
        model.language = shell.language
    }

    /// Hello + counters + filters only once there is something to show.
    private var showChrome: Bool { model.loaded && model.hasAny }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: HL.greeting(hour: Calendar.current.component(.hour, from: AppClock.now), name: model.userName, shell.language))
                    .susuType(.display).tracking(-0.3).foregroundStyle(Palette.ink)
                if showChrome {
                    HStack(spacing: 8) {
                        HText("hist.hint.hold")
                        HistoryKbd(text: model.dictationKey)
                        HText("hist.hint.dictate")
                    }
                    .susuType(.body).foregroundStyle(Palette.ink2).padding(.top, 10)
                    counters.padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            if showChrome { HistorySearchField(text: $model.query, focus: $searchFocused) }
        }
        .padding(.horizontal, 36).padding(.top, 28)
    }

    private var counters: some View {
        let c = model.counters
        let loc = HL.locale(shell.language)
        return HStack(spacing: 10) {
            counter(c?.totalWords ?? 0, "hist.c.words", loc)
            Text(verbatim: "·").foregroundStyle(Palette.ink3)
            counter(Int((c?.wordsPerMinute ?? 0).rounded()), "hist.c.wpm", loc)
            Text(verbatim: "·").foregroundStyle(Palette.ink3)
            counter(c?.streakDays ?? 0, "hist.c.days", loc)
        }
        .susuType(.body).foregroundStyle(Palette.ink2)
    }

    private func counter(_ n: Int, _ label: LocalizedStringKey, _ loc: Locale) -> some View {
        HStack(spacing: 4) {
            Text(n.formatted(.number.locale(loc))).susuType(.bodyStrong).monospacedDigit().foregroundStyle(Palette.ink)
            HText(label)
        }
    }

    // MARK: toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(HistoryKind.allCases, id: \.self) { k in
                    HistoryChip(title: k.title, isOn: model.kind == k) { model.kind = k }
                }
            }
            Spacer(minLength: 8)
            HistoryDropdown(label: "hist.f.app", selection: Binding(get: { model.appID ?? "" }, set: { model.appID = $0.isEmpty ? nil : $0 }),
                            options: [(value: "", title: HText("hist.f.apps"))]
                                + model.apps.map { (value: $0.bundleId, title: Text(verbatim: $0.appName)) })
            HistoryDropdown(label: "hist.f.status", selection: $model.statusFilter,
                            options: HistoryStatusFilter.allCases.map { (value: $0, title: HText($0.title)) })
            Text(verbatim: countLine).susuType(.caption).monospacedDigit().foregroundStyle(Palette.ink3)
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 36).padding(.top, 20)
    }

    private var countLine: String {
        if model.isSearching || model.isFiltered {
            let n = model.isSearching ? model.foundCount : model.summary.count
            return HL.string("hist.found", shell.language, n)
        }
        return HL.summary(model.summary, shell.language)
    }

    // MARK: feed

    @ViewBuilder private var feed: some View {
        if !model.loaded {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.hasAny {
            firstRun
        } else if model.sections.isEmpty {
            nothingFound
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.sections) { section in
                        Section {
                            ForEach(Array(section.items.enumerated()), id: \.element.id) { i, d in
                                HistoryRow(d: d, showsSeparator: i > 0, compact: model.selected != nil, model: model)
                                    .onAppear { if d.id == model.sections.last?.items.last?.id { model.loadMore() } }
                            }
                        } header: {
                            Text(verbatim: HL.dayTitle(section.day, calendar: model.calendar, shell.language))
                                .susuType(.title2).foregroundStyle(Palette.ink)
                                .padding(.horizontal, 12).padding(.top, 20).padding(.bottom, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Palette.bgCard)
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 48)
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
        }
    }

    private var firstRun: some View {
        VStack(spacing: Space.s3) {
            Image(systemName: "mic").font(.system(size: 32, weight: .light)).foregroundStyle(Palette.ink3)
            Text(verbatim: HL.string("hist.empty.title", shell.language, model.dictationKey))
                .susuType(.title2).foregroundStyle(Palette.ink).multilineTextAlignment(.center).frame(maxWidth: 380)
            HText("hist.empty.sub").susuType(.body).foregroundStyle(Palette.ink2)
            if actions.wisprFound {
                Button { model.importFromWispr() } label: {
                    HStack(spacing: 8) { Image(systemName: "square.and.arrow.down"); HText("hist.empty.import") }
                }
                .buttonStyle(.susu(.primary)).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 60)
    }

    private var nothingFound: some View {
        VStack(spacing: Space.s3) {
            if model.isSearching {
                Image(systemName: "magnifyingglass").font(.system(size: 32, weight: .light)).foregroundStyle(Palette.ink3)
                Text(verbatim: HL.string("hist.nores", shell.language, model.query.trimmingCharacters(in: .whitespaces)))
                    .susuType(.title2).foregroundStyle(Palette.ink).multilineTextAlignment(.center).frame(maxWidth: 380)
                Button { model.resetSearch() } label: { HText("hist.nores.reset") }.buttonStyle(.susu(.neutral))
            } else {
                Image(systemName: "clock").font(.system(size: 32, weight: .light)).foregroundStyle(Palette.ink3)
                HText("hist.fe").susuType(.title2).foregroundStyle(Palette.ink)
                Button { model.resetFilters() } label: { HText("hist.fe.reset") }.buttonStyle(.susu(.neutral))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 60)
    }
}

#Preview("History, light") {
    let model = ShellModel(services: .temporary())
    Task { try? await HistorySampleData.seed(into: model.services.history, styles: model.services.styles) }
    return ContentCard { HistoryScreen() }
        .shellRoot(model).environment(\.historyActions, .preview)
        .frame(width: 1000, height: 760).background(Palette.bg).preferredColorScheme(.light)
}

#Preview("History, dark") {
    let model = ShellModel(services: .temporary())
    Task { try? await HistorySampleData.seed(into: model.services.history, styles: model.services.styles) }
    return ContentCard { HistoryScreen() }
        .shellRoot(model).environment(\.historyActions, .preview)
        .frame(width: 1000, height: 760).background(Palette.bg).preferredColorScheme(.dark)
}

#Preview("History, empty") {
    let model = ShellModel(services: .temporary())
    return ContentCard { HistoryScreen() }
        .shellRoot(model).environment(\.historyActions, HistoryActions(wisprFound: true))
        .frame(width: 1000, height: 760).background(Palette.bg)
}
