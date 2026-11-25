import Foundation
import Testing
@testable import SusuCore

/// Fake judge: answers from a closure over the request text; records every request.
actor FakeJudgeLLM: ChatLLM {
    private(set) var requests: [ChatRequest] = []
    private let answer: @Sendable (String) -> String
    init(_ answer: @escaping @Sendable (String) -> String) { self.answer = answer }

    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        requests.append(request)
        return ChatResponse(text: answer(request.messages.last?.content ?? ""), model: request.model)
    }
}

/// Verdict by line: lines mentioning "SpeechKit"/"Claude" are recognition fixes, "Susu" is a new word, rest rewrite.
@Sendable func smartJudge(_ user: String) -> String {
    var items: [String] = []
    for line in user.split(separator: "\n") {
        guard let dot = line.firstIndex(of: "."), let id = Int(line[..<dot]) else { continue }
        let v = line.contains("SpeechKit") || line.contains("Claude") ? "recognition_fix"
            : line.contains("Susu") ? "new_word" : "rewrite"
        items.append("{\"id\":\(id),\"verdict\":\"\(v)\"}")
    }
    return "{\"results\":[\(items.joined(separator: ","))]}"
}

@Suite struct JudgeTests {
    let cands = [
        EditCandidate(before: "Яндекс Печкид", after: "SpeechKit", isReplacement: true),
        EditCandidate(before: "", after: "Susu", isReplacement: false),
        EditCandidate(before: "пошёл домой", after: "отправился спать", isReplacement: false),
    ]

    @Test func parsesVerdictsAndSendsOneSchemaRequest() async throws {
        let llm = FakeJudgeLLM(smartJudge)
        let out = try await EditLearner.judge(cands, llm: llm, model: "m")
        #expect(out.map(\.verdict) == [.recognitionFix, .newWord, .rewrite])
        #expect(out.map(\.isAccepted) == [true, true, false])
        let reqs = await llm.requests
        #expect(reqs.count == 1)
        #expect(reqs[0].jsonSchema?.name == "edit_verdicts")
        #expect(reqs[0].task == "judge" && reqs[0].model == "m")
    }

    @Test func toleratesCodeFencesAndMissingIds() async throws {
        let llm = FakeJudgeLLM { _ in "```json\n{\"results\":[{\"id\":1,\"verdict\":\"new_word\"},{\"id\":9,\"verdict\":\"new_word\"}]}\n```" }
        let out = try await EditLearner.judge(cands, llm: llm, model: "m")
        #expect(out.map(\.verdict) == [.rewrite, .newWord, .rewrite])
    }

    @Test func garbageAnswerMeansNothingAccepted() async throws {
        let llm = FakeJudgeLLM { _ in "sorry, I can't" }
        let out = try await EditLearner.judge(cands, llm: llm, model: "m")
        #expect(out.allSatisfy { !$0.isAccepted })
    }

    @Test func emptyInputSkipsTheRequest() async throws {
        let llm = FakeJudgeLLM(smartJudge)
        #expect(try await EditLearner.judge([], llm: llm, model: "m").isEmpty)
        #expect(await llm.requests.isEmpty)
    }

    @Test func applyAddsWordsAndSkipsRewrites() async throws {
        let d = DictionaryService(database: try SusuDatabase.inMemory())
        let llm = FakeJudgeLLM(smartJudge)
        let judged = try await EditLearner.judge(cands, llm: llm, model: "m")
        let added = try await EditLearner.apply(judged, to: d)
        #expect(added.map(\.phrase).sorted() == ["SpeechKit", "Susu"])
        #expect(added.allSatisfy { $0.kind == "word" && $0.origin == "learned" })
        // Seeing the same fix again: the word is known, so only the repeated distortion is stored, once.
        let second = try await EditLearner.apply(judged, to: d)
        #expect(second.map(\.kind) == ["replacement"])
        let third = try await EditLearner.apply(judged, to: d)
        #expect(third.isEmpty)
    }

    @Test func repeatingDistortionBecomesReplacement() async throws {
        let d = DictionaryService(database: try SusuDatabase.inMemory())
        let fix = EditCandidate(before: "Яндекс Печкид", after: "SpeechKit", isReplacement: true)
        // First time: only the word.
        _ = try await EditLearner.apply([JudgedCandidate(candidate: fix, verdict: .recognitionFix)], to: d)
        #expect(try await d.list(kind: "replacement").isEmpty)
        // Same target heard differently later: the word is known, so this is a replacement.
        let again = EditCandidate(before: "спичкит", after: "SpeechKit", isReplacement: true)
        let added = try await EditLearner.apply([JudgedCandidate(candidate: again, verdict: .recognitionFix)], to: d)
        #expect(added.first?.kind == "replacement" && added.first?.replacement == "SpeechKit")
        // Counted repeats make a replacement right away.
        let cc = EditCandidate(before: "клод код", after: "Claude Code", isReplacement: true)
        let r = try await EditLearner.apply([JudgedCandidate(candidate: cc, verdict: .recognitionFix, count: 5)], to: d)
        #expect(r.first?.kind == "replacement")
        #expect(try await d.editorExamples().count == 2)
    }
}

@Suite struct BatchLearnerTests {
    static func syntheticPairs(_ n: Int) -> [(final: String, edited: String)] {
        let names = ["Яндекс Печкид": "SpeechKit", "клод код": "Claude Code", "люмира": "Lumera"]
        let filler = "сегодня мы обсуждаем план работы на следующую неделю и договариваемся о сроках по задачам команды"
        return (0..<n).map { i in
            let (bad, good) = names.sorted { $0.key < $1.key }[i % 3]
            let tail = " пункт \(i % 50)"
            switch i % 4 {
            case 0: return ("\(filler) \(bad) \(filler)\(tail)", "\(filler) \(good) \(filler)\(tail)")
            case 1: return ("\(filler) \(bad).\(tail)", "\(filler) \(good).\(tail)")
            case 2: return ("\(filler)\(tail)", "Тот же \(filler)\(tail)")  // stop-word-free insertion of "Тот же"
            default: return (filler, filler)  // untouched
            }
        }
    }

    @Test func aggregationCountsRepeatsCaseInsensitively() {
        let pairs: [(final: String, edited: String)] = [
            ("открой клод код", "открой Claude Code"),
            ("запусти Клод Код", "запусти Claude Code"),
            ("а вот клод код", "а вот Claude Code"),
            ("поставь люмира", "поставь Lumera"),
            ("без правок", "без правок"),
        ]
        let agg = BatchLearner.aggregate(pairs: pairs)
        #expect(agg.count == 2)
        #expect(agg[0].count == 3 && agg[0].candidate.after == "Claude Code")
        #expect(agg[1].count == 1 && agg[1].candidate.after == "Lumera")
    }

    @Test func aggregationSkipsKnown() {
        let agg = BatchLearner.aggregate(pairs: [("открой клод код", "открой Claude Code")], known: ["клод код"])
        #expect(agg.isEmpty)
    }

    @Test func aggregates17kPairsFast() {
        let pairs = Self.syntheticPairs(17_000)
        let start = Date()
        let agg = BatchLearner.aggregate(pairs: pairs)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 10, "took \(elapsed)s")
        let speech = agg.first { $0.candidate.after == "SpeechKit" }
        #expect(speech != nil && speech!.count > 1000)
    }

    @Test func judgesOnlyUniqueCandidatesInBatches() async throws {
        let llm = FakeJudgeLLM(smartJudge)
        let learner = BatchLearner(llm: llm, model: "m", batchSize: 2, maxJudged: 100, concurrency: 2)
        let pairs = Self.syntheticPairs(2_000)
        let agg = BatchLearner.aggregate(pairs: pairs)
        let out = try await learner.run(pairs: pairs)
        let reqs = await llm.requests
        #expect(reqs.count == (agg.count + 1) / 2)       // unique candidates, not 2000 edits
        #expect(out.allSatisfy { $0.isAccepted })
        #expect(out.map(\.count) == out.map(\.count).sorted(by: >))
        #expect(out.contains { $0.candidate.after == "SpeechKit" && $0.verdict == .recognitionFix })
        #expect(!out.contains { $0.candidate.after == "Тот же" })
    }

    @Test func maxJudgedKeepsMostRepeated() async throws {
        let llm = FakeJudgeLLM(smartJudge)
        let learner = BatchLearner(llm: llm, model: "m", batchSize: 10, maxJudged: 1)
        let out = try await learner.run(pairs: [
            ("a клод код", "a Claude Code"), ("b клод код", "b Claude Code"), ("c люмира", "c Lumera"),
        ].map { (final: $0.0, edited: $0.1) })
        #expect(out.count == 1 && out[0].candidate.after == "Claude Code" && out[0].count == 2)
    }

    @Test func nothingIsAddedUntilAddSelected() async throws {
        let d = DictionaryService(database: try SusuDatabase.inMemory())
        let llm = FakeJudgeLLM(smartJudge)
        let learner = BatchLearner(llm: llm, model: "m")
        let out = try await learner.run(pairs: [
            (final: "открой клод код", edited: "открой Claude Code"),
            (final: "поставь люмира", edited: "поставь Lumera"),
        ], known: try await d.knownPhrases())
        #expect(try await d.list().isEmpty)
        // The user ticks only Claude Code.
        let picked = out.filter { $0.candidate.after == "Claude Code" }
        let added = try await BatchLearner.addSelected(picked, to: d)
        #expect(added.count == 1)
        #expect(try await d.list().map(\.origin) == ["history"])
    }
}
