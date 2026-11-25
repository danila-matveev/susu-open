import Foundation

/// One unique candidate found across many edits, with how many edits produced it.
public struct AggregatedCandidate: Sendable, Equatable {
    public var candidate: EditCandidate
    public var count: Int
}

/// "Find words in history" (T4.3, spec 3.7): the live learning algorithm run over many (final, edited) pairs.
/// Nothing is added to the dictionary until `addSelected` is called with the user's choice (И8).
public struct BatchLearner: Sendable {
    public var llm: any ChatLLM
    public var model: String
    /// Candidates per judge request.
    public var batchSize: Int
    /// Only the most repeated unique candidates go to the judge (keeps 17k edits within minutes and a few cents).
    public var maxJudged: Int
    /// Judge requests in flight at once.
    public var concurrency: Int

    public init(llm: any ChatLLM, model: String, batchSize: Int = 40, maxJudged: Int = 600, concurrency: Int = 4) {
        self.llm = llm; self.model = model
        self.batchSize = max(1, batchSize); self.maxJudged = max(1, maxJudged); self.concurrency = max(1, concurrency)
    }

    // MARK: Non-LLM part

    /// Runs `EditLearner.candidates` on every pair and merges equal candidates (case-insensitive).
    /// Sorted by count descending, then alphabetically, so the result is stable.
    public static func aggregate(pairs: [(final: String, edited: String)], known: Set<String> = [])
        -> [AggregatedCandidate] {
        let known = Set(known.map(EditLearner.normalize))
        var table: [String: AggregatedCandidate] = [:]
        for p in pairs where p.final != p.edited {
            for c in EditLearner.candidates(inserted: p.final, edited: p.edited, known: known) {
                if table[c.key] != nil { table[c.key]!.count += 1 } else {
                    table[c.key] = AggregatedCandidate(candidate: c, count: 1)
                }
            }
        }
        return table.values.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.candidate.key < $1.candidate.key
        }
    }

    // MARK: Judge

    /// Judges the unique candidates in batches (top `maxJudged` by count) and returns the accepted ones,
    /// most repeated first.
    public func run(pairs: [(final: String, edited: String)], known: Set<String> = []) async throws -> [JudgedCandidate] {
        try await judge(Self.aggregate(pairs: pairs, known: known))
    }

    public func judge(_ aggregated: [AggregatedCandidate]) async throws -> [JudgedCandidate] {
        let top = Array(aggregated.prefix(maxJudged))
        let chunks = stride(from: 0, to: top.count, by: batchSize).map { Array(top[$0..<min($0 + batchSize, top.count)]) }
        let llm = self.llm, model = self.model
        var results: [JudgedCandidate] = []
        try await withThrowingTaskGroup(of: [JudgedCandidate].self) { group in
            var next = 0
            func launch() {
                guard next < chunks.count else { return }
                let chunk = chunks[next]; next += 1
                group.addTask {
                    try await EditLearner.judgeWeighted(chunk.map { ($0.candidate, $0.count) }, llm: llm, model: model)
                }
            }
            for _ in 0..<min(concurrency, chunks.count) { launch() }
            while let batch = try await group.next() {
                results += batch
                launch()
            }
        }
        return results.filter(\.isAccepted).sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.candidate.key < $1.candidate.key
        }
    }

    // MARK: Add

    /// Adds only what the user ticked, as `origin = history` entries.
    @discardableResult
    public static func addSelected(_ selected: [JudgedCandidate], to dictionary: DictionaryService,
                                   now: Date = Date()) async throws -> [DictionaryEntry] {
        try await EditLearner.apply(selected, to: dictionary, origin: "history", now: now)
    }
}
