// State and logic of the History screen: filters, search, paged feed, selection, audio, delete-with-undo, compare.
import AppKit
import AVFoundation
import SwiftUI
import SusuCore

enum HistoryKind: CaseIterable, Hashable {
    case all, dictation, agent, calls
    var title: LocalizedStringKey {
        switch self {
        case .all: "hist.f.all"
        case .dictation: "hist.f.dictation"
        case .agent: "hist.f.agent"
        case .calls: "hist.f.calls"
        }
    }
}

enum HistoryStatusFilter: CaseIterable, Hashable {
    case any, notPasted, failed, cancelled, fallback
    var title: LocalizedStringKey {
        switch self {
        case .any: "hist.st.any"
        case .notPasted: "hist.st.notPasted"
        case .failed: "hist.st.failed"
        case .cancelled: "hist.st.cancelled"
        case .fallback: "hist.st.fallback"
        }
    }
}

struct HistoryDaySection: Identifiable, Equatable {
    var day: Date
    var items: [Dictation]
    var id: Date { day }
}

struct HistoryToast: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var detail: String?
    var actionTitle: String?
    var action: (@MainActor () -> Void)?
    static func == (a: HistoryToast, b: HistoryToast) -> Bool { a.id == b.id }
}

enum ComparePhase: Equatable {
    case loading
    case ready(String)
    case failed(String)
}

struct CompareState {
    var record: Dictation
    var options: CompareOptions
    var choice: CompareChoice
    var phase: ComparePhase = .loading
}

@MainActor
final class HistoryModel: ObservableObject {
    static let pageSize = 60
    static let searchLimit = 200

    let services: AppServices
    var actions: HistoryActions = .none
    var language: InterfaceLanguage = .system
    let calendar: Calendar
    let userName: String

    var history: HistoryStore { services.history }

    // Filters
    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    @Published var kind: HistoryKind = .all { didSet { if kind != oldValue { filtersChanged() } } }
    @Published var appID: String? { didSet { if appID != oldValue { filtersChanged() } } }
    @Published var statusFilter: HistoryStatusFilter = .any { didSet { if statusFilter != oldValue { filtersChanged() } } }

    // Data
    @Published private(set) var sections: [HistoryDaySection] = []
    @Published private(set) var loaded = false
    @Published private(set) var hasAny = false
    @Published private(set) var counters: HistoryCounters?
    @Published private(set) var summary = HistorySummary(count: 0, days: 0)
    @Published private(set) var apps: [HistoryAppEntry] = []
    @Published private(set) var styleNames: [String: String] = [:]
    @Published private(set) var foundCount = 0

    // Interaction
    @Published var selectedID: String?
    @Published private(set) var rawShown: Set<String> = []
    @Published private(set) var retrying: Set<String> = []
    @Published private(set) var toast: HistoryToast?
    @Published var compare: CompareState?

    // Audio
    @Published private(set) var playingID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var playDuration: Double = 0

    private var items: [Dictation] = []
    private var next: FeedCursor?
    private var loadingMore = false
    private var generation = 0
    private var searchTask: Task<Void, Never>?
    private var hidden: Set<String> = []
    private var pendingDeletes: [String: Task<Void, Never>] = [:]
    private var toastTask: Task<Void, Never>?
    private var compareTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var playTask: Task<Void, Never>?

    init(services: AppServices, calendar: Calendar = .current,
         userName: String = HistoryModel.systemFirstName()) {
        self.services = services; self.calendar = calendar; self.userName = userName
    }

    static func systemFirstName() -> String {
        if let name = AppClock.fixedFirstName { return name }
        return NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var isFiltered: Bool { kind != .all || appID != nil || statusFilter != .any }
    var selected: Dictation? { selectedID.flatMap { id in items.first { $0.id == id } } }

    var dictationKey: String { HL.hotkey(services.settings.current.hotkeys.dictation, language) }

    var filter: HistoryFilter {
        var f = HistoryFilter()
        switch kind {
        case .dictation: f.kind = .dictation
        case .agent: f.kind = .agent
        case .all, .calls: break
        }
        f.bundleId = appID
        switch statusFilter {
        case .any: break
        case .notPasted: f.statuses = [.notInserted, .copiedOnly]
        case .failed: f.statuses = [.failed]
        case .cancelled: f.statuses = [.cancelled]
        case .fallback: f.fallbackUsed = true
        }
        return f
    }

    // MARK: Loading

    /// Runs for the lifetime of the screen: first load, then reloads on any change in the database.
    func run() async {
        await refresh()
        loaded = true
        let changes = Task { @MainActor [self] in
            var first = true
            do {
                for try await _ in history.observeChanges(limit: 1) {
                    if first { first = false; continue }
                    await refresh(keepCount: true)
                }
            } catch {}
        }
        let counts = Task { @MainActor [self] in
            do { for try await c in history.observeCounters(calendar: calendar) { counters = c } } catch {}
        }
        await withTaskCancellationHandler {
            await changes.value
            await counts.value
        } onCancel: {
            changes.cancel(); counts.cancel()
        }
    }

    private func filtersChanged() {
        items = []; next = nil; selectedID = nil
        rebuild()
        scheduleSearch(delay: 0)
    }

    private func scheduleSearch(delay: Int = 120) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func refresh(keepCount: Bool = false) async {
        generation += 1
        let gen = generation
        let f = filter, q = query.trimmingCharacters(in: .whitespaces), cal = calendar
        do {
            var newItems: [Dictation] = []
            var newNext: FeedCursor?
            if kind == .calls {
                // No call records yet (T3.8+ adds them).
            } else if !q.isEmpty {
                newItems = try await history.search(q, filter: f, limit: Self.searchLimit)
            } else {
                let limit = keepCount ? max(Self.pageSize, items.count) : Self.pageSize
                let page = try await history.feed(filter: f, limit: limit, calendar: cal)
                newItems = page.days.flatMap(\.items)
                newNext = page.next
            }
            guard gen == generation else { return }
            items = newItems; next = newNext
            if !q.isEmpty { foundCount = newItems.count }
            rebuild()
            if q.isEmpty {
                summary = kind == .calls ? HistorySummary(count: 0, days: 0)
                    : try await history.summary(filter: f, calendar: cal)
            }
            if !isFiltered && !isSearching { hasAny = !newItems.isEmpty }
            else { hasAny = try await !history.feed(limit: 1).days.isEmpty }
            apps = try await history.apps()
            let styles = try await services.styles.styles()
            styleNames = Dictionary(styles.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        } catch {
            // A failed read leaves the previous list on screen; the next change reloads it.
        }
    }

    func loadMore() {
        guard let cursor = next, !loadingMore, !isSearching else { return }
        loadingMore = true
        let gen = generation, f = filter, cal = calendar
        Task {
            defer { loadingMore = false }
            guard let page = try? await history.feed(filter: f, after: cursor, limit: Self.pageSize, calendar: cal),
                  gen == generation else { return }
            items += page.days.flatMap(\.items)
            next = page.next
            rebuild()
        }
    }

    private func rebuild() {
        var out: [HistoryDaySection] = []
        for d in items where !hidden.contains(d.id) {
            let day = calendar.startOfDay(for: d.createdAt)
            if out.last?.day == day { out[out.count - 1].items.append(d) } else {
                out.append(HistoryDaySection(day: day, items: [d]))
            }
        }
        sections = out
    }

    func resetFilters() { kind = .all; appID = nil; statusFilter = .any }
    func resetSearch() { query = "" }

    // MARK: Row actions

    func select(_ d: Dictation) { selectedID = selectedID == d.id ? nil : d.id }

    func copy(_ d: Dictation) {
        guard d.hasText else { return }
        put(d.displayText)
        show(HL.string("hist.t.copied", language), duration: 1.5)
    }

    func pasteAgain(_ d: Dictation) {
        guard d.hasText else { return }
        put(d.displayText)
        actions.pasteAgain(d)
        show(HL.string("hist.t.paste", language), detail: HL.string("hist.t.paste.d", language), duration: 3)
    }

    private func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func toggleRaw(_ d: Dictation) {
        if rawShown.contains(d.id) { rawShown.remove(d.id) } else { rawShown.insert(d.id) }
    }

    func retry(_ d: Dictation) {
        guard !retrying.contains(d.id) else { return }
        retrying.insert(d.id)
        Task {
            let r = await actions.retry(d)
            retrying.remove(d.id)
            report(r)
            await refresh(keepCount: true)
        }
    }

    func redo(_ d: Dictation) {
        guard !retrying.contains(d.id) else { return }
        retrying.insert(d.id)
        Task {
            let r = await actions.redo(d)
            retrying.remove(d.id)
            report(r)
            await refresh(keepCount: true)
        }
    }

    func undoAgent(_ d: Dictation) {
        Task { report(await actions.undoAgent(d)); await refresh(keepCount: true) }
    }

    private func report(_ r: HistoryActionResult) {
        switch r {
        case .done(let message): if let message { show(message, duration: 3) }
        case .unavailable: show(HL.string("hist.t.unavailable", language), duration: 2.5)
        }
    }

    func importFromWispr() { actions.importFromWispr() }

    func saveAudio(_ d: Dictation) {
        guard let src = history.audioURL(for: d) else {
            show(HL.string("hist.audio.gone", language), duration: 3)
            return
        }
        let panel = NSSavePanel()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        panel.nameFieldStringValue = "Susu \(f.string(from: d.createdAt)).\(src.pathExtension.isEmpty ? "wav" : src.pathExtension)"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: src, to: dest)
            show(HL.string("hist.t.saved", language), detail: dest.deletingLastPathComponent().lastPathComponent, duration: 3)
        } catch {
            show(HL.string("hist.t.saveFailed", language), duration: 3)
        }
    }

    // MARK: Delete with undo

    /// Hides the row now; the record (and its audio) is deleted for real after 5 s unless the user undoes it.
    func delete(_ d: Dictation) {
        stopPlayback(if: d.id)
        hidden.insert(d.id)
        if selectedID == d.id { selectedID = nil }
        rebuild()
        let id = d.id
        pendingDeletes[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await self?.commitDelete(id)
        }
        let lang = language
        show(HL.string("hist.t.deleted", lang), actionTitle: HL.string("hist.undo", lang), duration: 5, icon: true) { [weak self] in
            self?.undoDelete(id)
        }
    }

    private func undoDelete(_ id: String) {
        pendingDeletes.removeValue(forKey: id)?.cancel()
        hidden.remove(id)
        rebuild()
        toast = nil
    }

    private func commitDelete(_ id: String) async {
        pendingDeletes[id] = nil
        try? await history.softDelete(id: id)
        hidden.remove(id)
        await refresh(keepCount: true)
    }

    /// Called when the screen goes away: deletes that were waiting for their 5 seconds happen now.
    func flushPendingDeletes() {
        let ids = Array(pendingDeletes.keys)
        for (_, t) in pendingDeletes { t.cancel() }
        pendingDeletes = [:]
        for id in ids { Task { [history] in try? await history.softDelete(id: id) } }
        stopPlayback()
    }

    // MARK: Toast

    func show(_ title: String, detail: String? = nil, actionTitle: String? = nil, duration: Double = 3,
              icon: Bool = false, action: (@MainActor () -> Void)? = nil) {
        toastTask?.cancel()
        let t = HistoryToast(title: title, detail: detail, actionTitle: actionTitle, action: action)
        toast = t
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            if self?.toast?.id == t.id { self?.toast = nil }
        }
    }

    func dismissToast() { toast = nil }

    // MARK: Audio

    func togglePlay(_ d: Dictation) {
        if playingID == d.id, let p = player {
            if p.isPlaying { p.pause(); isPlaying = false; playTask?.cancel() } else { p.play(); isPlaying = true; startTicking() }
            return
        }
        guard let url = history.audioURL(for: d), let p = try? AVAudioPlayer(contentsOf: url) else {
            show(HL.string("hist.audio.gone", language), duration: 3)
            return
        }
        stopPlayback()
        player = p
        playingID = d.id
        playDuration = p.duration
        progress = 0
        p.play()
        isPlaying = true
        startTicking()
    }

    func seek(_ fraction: Double, _ d: Dictation) {
        if playingID != d.id {
            togglePlay(d)
            if playingID != d.id { return }
        }
        guard let p = player else { return }
        p.currentTime = max(0, min(1, fraction)) * p.duration
        progress = fraction
    }

    private func startTicking() {
        playTask?.cancel()
        playTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let p = self.player else { return }
                if p.isPlaying { self.progress = p.duration > 0 ? p.currentTime / p.duration : 0 }
                else if self.isPlaying { self.stopPlayback(); return }  // reached the end
            }
        }
    }

    func stopPlayback(if id: String? = nil) {
        if let id, playingID != id { return }
        playTask?.cancel()
        player?.stop(); player = nil
        playingID = nil; isPlaying = false; progress = 0
    }

    func audioAvailable(_ d: Dictation) -> Bool { d.audioPath != nil }

    // MARK: Compare

    func compareOptions(for d: Dictation) -> CompareOptions {
        if let o = actions.compareOptions?(d) { return o }
        var models: [CompareOption] = []
        for p in services.registry.providers {
            for price in p.prices where price.inputPerMTok != nil {
                let id = "\(p.id.rawValue)/\(price.model)"
                models.append(CompareOption(id: id, title: "\(p.displayName) · \(price.model)",
                                            isCurrent: price.model == d.editorModel))
            }
        }
        if !models.contains(where: \.isCurrent), let m = d.editorModel {
            models.insert(CompareOption(id: m, title: m, isCurrent: true), at: 0)
        }
        let styles = styleNames.sorted { $0.value < $1.value }.map {
            CompareOption(id: $0.key, title: $0.value, isCurrent: $0.key == d.styleId)
        }
        return CompareOptions(models: models, styles: styles)
    }

    func openCompare(_ d: Dictation, style: Bool = false) {
        guard d.hasText else { return }
        let options = compareOptions(for: d)
        var choice = CompareChoice()
        if style {
            choice.styleID = options.styles.first { !$0.isCurrent }?.id ?? options.styles.first?.id
        } else {
            choice.modelID = options.models.first { !$0.isCurrent }?.id ?? options.models.first?.id
        }
        compare = CompareState(record: d, options: options, choice: choice)
        runCompare()
    }

    func setCompare(model: String?, style: String?) {
        compare?.choice = CompareChoice(modelID: model, styleID: style)
        runCompare()
    }

    private func runCompare() {
        compareTask?.cancel()
        guard var state = compare else { return }
        state.phase = .loading
        compare = state
        let d = state.record, choice = state.choice, lang = language
        compareTask = Task { [weak self] in
            guard let self else { return }
            let phase: ComparePhase
            do {
                phase = .ready(try await actions.compare(d, choice))
            } catch let e as CompareNoKeyError {
                let name = state.options.models.first { $0.id == choice.modelID }?.title ?? e.model
                phase = .failed(name.isEmpty ? HL.string("hist.cmp.err.generic", lang) : HL.string("hist.cmp.err.nokey", lang, name))
            } catch {
                phase = .failed(HL.string("hist.cmp.err.generic", lang))
            }
            guard !Task.isCancelled else { return }
            compare?.phase = phase
        }
    }

    func closeCompare() { compareTask?.cancel(); compare = nil }

    /// «Оставить этот» on the right side: the new text becomes the final text.
    func keepCompared(_ text: String) {
        guard let state = compare else { return }
        let id = state.record.id
        let modelTitle = state.choice.modelID   // store the model id, not its display title
        let styleID = state.choice.styleID
        closeCompare()
        Task {
            _ = try? await history.update(id: id) { d in
                d.finalText = text
                d.editedText = nil
                if let modelTitle { d.editorModel = modelTitle }
                if let styleID { d.styleId = styleID }
            }
            await refresh(keepCount: true)
            show(HL.string("hist.t.replaced", language), duration: 3)
        }
    }

    func keepOriginal() {
        closeCompare()
        show(HL.string("hist.t.kept", language), duration: 3)
    }
}
