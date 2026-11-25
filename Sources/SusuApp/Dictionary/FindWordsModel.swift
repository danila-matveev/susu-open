// «Найти слова в истории»: history pairs -> candidates (BatchLearner.aggregate) -> editor model judges -> user ticks.
// Nothing reaches the dictionary until `addSelected` (spec 3.7, И8).
import SwiftUI
import SusuCore

/// Records the judge's token cost in the spend log, like every other model call.
private struct SpendingChat: ChatLLM {
    let base: any ChatLLM
    let spend: SpendLog
    let provider: ProviderID
    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        let response = try await base.complete(request)
        _ = try? await spend.recordChat(task: request.task, provider: provider, model: request.model, usage: response.usage)
        return response
    }
}

@MainActor
final class FindWordsModel: ObservableObject {
    enum Phase: Equatable {
        case reading, scanning, judging, results
        /// `noEdits`: the history has no corrected dictations at all (else: everything found is already known).
        case empty(noEdits: Bool)
        case failed(String)
    }

    struct Row: Identifiable {
        let id: String
        let judged: JudgedCandidate
        var candidate: EditCandidate { judged.candidate }
    }

    @Published private(set) var phase: Phase = .reading
    @Published private(set) var fraction = 0.0
    @Published private(set) var checked = 0
    @Published private(set) var total = 0
    @Published private(set) var rows: [Row] = []
    @Published var selected: Set<String> = []
    /// False when no editor key exists: the list is not checked by a model.
    @Published private(set) var isJudged = true

    private let services: AppServices
    private var task: Task<Void, Never>?
    /// Unjudged lists are capped so the sheet stays usable.
    private let unjudgedLimit = 300

    init(services: AppServices) { self.services = services }

    func start() {
        task?.cancel()
        selected = []; rows = []; fraction = 0; checked = 0; total = 0; phase = .reading
        task = Task { [weak self] in
            guard let self else { return }
            do { try await self.run() } catch is CancellationError {} catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() { task?.cancel() }

    private func editorChoice() -> ProviderChoice? {
        guard let choice = services.settings.current.providers.editor else { return nil }
        if services.registry.info(for: choice.providerID)?.needsKey ?? false {
            guard ((try? services.secrets.get(choice.providerID)) ?? nil) != nil else { return nil }
        }
        return choice
    }

    private func run() async throws {
        let choice = editorChoice()
        isJudged = choice != nil

        let pairs = try await HistoryPairs.load(from: services.history)
        guard !pairs.isEmpty else { phase = .empty(noEdits: true); return }

        total = pairs.count
        phase = .scanning
        fraction = 0.04
        let scanShare = choice == nil ? 0.96 : 0.36
        let known = try await services.dictionary.knownPhrases()
        var table: [String: AggregatedCandidate] = [:]
        let step = 500
        for start in stride(from: 0, to: pairs.count, by: step) {
            try Task.checkCancellation()
            let chunk = Array(pairs[start..<min(start + step, pairs.count)])
            let part = await Task.detached { BatchLearner.aggregate(pairs: chunk, known: known) }.value
            for a in part {
                let key = Self.key(a.candidate)
                if table[key] != nil { table[key]!.count += a.count } else { table[key] = a }
            }
            checked = min(pairs.count, start + step)
            fraction = 0.04 + scanShare * Double(checked) / Double(pairs.count)
        }
        let aggregated = table.values.sorted(by: Self.byCountThenWord)
        guard !aggregated.isEmpty else { phase = .empty(noEdits: false); return }

        var found: [JudgedCandidate]
        if let choice {
            phase = .judging
            let chat = try services.registry.makeChat(choice, secrets: services.secrets)
            let learner = BatchLearner(llm: SpendingChat(base: chat, spend: services.spend, provider: choice.providerID),
                                       model: choice.model)
            let top = Array(aggregated.prefix(learner.maxJudged))
            let slice = learner.batchSize * learner.concurrency
            found = []
            for start in stride(from: 0, to: top.count, by: slice) {
                try Task.checkCancellation()
                found += try await learner.judge(Array(top[start..<min(start + slice, top.count)]))
                fraction = 0.4 + 0.6 * Double(min(top.count, start + slice)) / Double(top.count)
            }
            found.sort {
                $0.count != $1.count ? $0.count > $1.count : $0.candidate.after.lowercased() < $1.candidate.after.lowercased()
            }
        } else {
            found = aggregated.prefix(unjudgedLimit).map {
                JudgedCandidate(candidate: $0.candidate, verdict: $0.candidate.isReplacement ? .recognitionFix : .newWord,
                                count: $0.count)
            }
        }
        guard !found.isEmpty else { phase = .empty(noEdits: false); return }
        rows = found.map { Row(id: Self.key($0.candidate), judged: $0) }
        fraction = 1
        phase = .results
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func toggleAll() {
        selected = selected.count == rows.count ? [] : Set(rows.map(\.id))
    }

    /// Adds only the ticked rows (origin `history`). Returns what was really added.
    func addSelected() async throws -> [DictionaryEntry] {
        let chosen = rows.filter { selected.contains($0.id) }.map(\.judged)
        guard !chosen.isEmpty else { return [] }
        return try await BatchLearner.addSelected(chosen, to: services.dictionary)
    }

    private static func key(_ c: EditCandidate) -> String {
        normalizedPhrase(c.before) + "\u{1F}" + normalizedPhrase(c.after)
    }

    private static func byCountThenWord(_ a: AggregatedCandidate, _ b: AggregatedCandidate) -> Bool {
        a.count != b.count ? a.count > b.count : key(a.candidate) < key(b.candidate)
    }
}
