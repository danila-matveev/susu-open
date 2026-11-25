import Foundation

/// What the editor step did (spec 3.4, step 2).
public struct EditorResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// The model's text (checked) is the result.
        case used
        /// No call: level `verbatim`, empty text, or nothing to fix (no dictionary).
        case skipped
        /// Deadline passed: the rules text is the result.
        case timedOut
        /// The call failed: the rules text is the result.
        case failed(String)
        /// The model answered, the check threw it away: the rules text is the result.
        case rejected(EditorRejection)
    }

    /// What to insert.
    public var text: String
    /// Model that answered (nil when no call was made or it failed).
    public var model: String?
    public var costUSD: Double?
    /// True when `text` comes from the model.
    public var usedModel: Bool
    public var outcome: Outcome
    /// The model's answer before the check (for the bench and logs); nil when there was none.
    public var modelText: String?
    /// Wall time of the whole step.
    public var latencyMs: Int
}

/// Step 2 of cleanup (spec 3.4): a fast language model on top of the rules text.
public enum Editor {
    /// Total deadline per level (spec 3.4): 350 ms for names, 1.5 s for the rest.
    public static func defaultTimeout(for level: CleanupLevel) -> TimeInterval {
        level == .names ? 0.35 : 1.5
    }

    /// - Parameters:
    ///   - text: the text after `CleanupRules.apply`.
    ///   - terms: dictionary words (up to 200 are sent), in the spelling to be written.
    ///   - examples: "was -> became" pairs, up to 10 are sent (`DictionaryService.editorExamples`).
    ///   - timeout: total deadline; default per level.
    /// Never throws: on timeout, error or a rejected answer the result carries `text` unchanged.
    public static func edit(text: String, level: CleanupLevel, context: EditorContext = EditorContext(),
                            terms: [String] = [], examples: [(before: String, after: String)] = [],
                            chat: any ChatLLM, model: String, timeout: TimeInterval? = nil) async -> EditorResult {
        let started = ContinuousClock.now
        func elapsed() -> Int {
            let d = ContinuousClock.now - started
            return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
        }
        func fallback(_ outcome: EditorResult.Outcome, model: String? = nil, cost: Double? = nil, raw: String? = nil) -> EditorResult {
            EditorResult(text: text, model: model, costUSD: cost, usedModel: false, outcome: outcome, modelText: raw, latencyMs: elapsed())
        }

        let hasDictionary = !terms.isEmpty || !examples.isEmpty
        if level == .verbatim || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (level == .names && !hasDictionary) {
            return fallback(.skipped)
        }

        let deadline = timeout ?? defaultTimeout(for: level)
        let system = EditorPrompt.system(level: level, context: context, terms: terms, examples: examples)
        let request = ChatRequest(
            model: model, messages: [.system(system), .user(text)], temperature: 0,
            maxTokens: min(4096, Int(Double(text.count) * 1.3) + 400), timeout: deadline, task: "editor")

        let response: ChatResponse
        do {
            response = try await withDeadline(deadline) { try await chat.complete(request) }
        } catch is EditorTimeout {
            return fallback(.timedOut)
        } catch {
            return fallback(.failed(String(describing: error)))
        }

        let answer = EditorPrompt.clean(response.text)
        switch EditorCheck.verdict(input: text, output: answer, level: level, terms: terms + examples.map(\.after)) {
        case .accept(let checked):
            return EditorResult(text: checked, model: response.model, costUSD: response.usage.costUSD, usedModel: true,
                                outcome: .used, modelText: answer, latencyMs: elapsed())
        case .reject(let why):
            return fallback(.rejected(why), model: response.model, cost: response.usage.costUSD, raw: answer)
        }
    }

    /// Latin words of `output` found neither in `input` nor in the dictionary (Р5); for logs and the bench.
    public static func inventedLatinWords(input: String, output: String, terms: [String]) -> [String] {
        EditorCheck.inventedLatin(input: input, output: output, terms: terms)
    }

    struct EditorTimeout: Error {}

    /// Runs `operation`; if it does not finish in time, cancels it and throws `EditorTimeout`.
    static func withDeadline<T: Sendable>(_ seconds: TimeInterval,
                                          _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw EditorTimeout()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw EditorTimeout() }
            return first
        }
    }
}
