import Foundation
import Testing
@testable import SusuCore

@Suite struct FallbackTests {
    let req = ChatRequest(model: "a", messages: [.user("x")])
    let ok = ChatResponse(text: "ok", model: "b")

    @Test func primaryAnswersNoFallback() async throws {
        let f = FallbackChat(primary: FakeChat(result: .success(ok)), secondary: FakeChat(result: .failure(.timeout)))
        let r = try await f.completeReporting(req)
        #expect(!r.usedFallback && r.primaryError == nil && r.response.text == "ok")
    }

    @Test(arguments: [ChatError.unauthorized, .outOfCredit, .timeout, .noNetwork, .rateLimited, .http(502, "")])
    func switchesToSecondary(error: ChatError) async throws {
        let f = FallbackChat(primary: FakeChat(result: .failure(error)), secondary: FakeChat(result: .success(ok)))
        let r = try await f.completeReporting(req)
        #expect(r.usedFallback && r.primaryError == error)
    }

    @Test func doesNotSwitchOnClientErrors() async {
        let f = FallbackChat(primary: FakeChat(result: .failure(.http(400, "bad"))), secondary: FakeChat(result: .success(ok)))
        await #expect(throws: ChatError.http(400, "bad")) { try await f.complete(req) }
    }

    @Test func noSecondaryRethrows() async {
        let f = FallbackChat(primary: FakeChat(result: .failure(.timeout)), secondary: nil)
        await #expect(throws: ChatError.timeout) { try await f.complete(req) }
    }

    @Test func secondaryFailureSurfaces() async {
        let f = FallbackChat(primary: FakeChat(result: .failure(.timeout)), secondary: FakeChat(result: .failure(.unauthorized)))
        await #expect(throws: ChatError.unauthorized) { try await f.complete(req) }
    }
}

@Suite struct RegistryAndSpendTests {
    @Test func estimatesCosts() throws {
        let reg = ProviderRegistry.builtIn
        let chat = try #require(reg.estimateCost(provider: .groq, model: "llama-3.1-8b-instant", tokensIn: 1_000_000, tokensOut: 1_000_000))
        #expect(abs(chat - 0.13) < 1e-9)
        let stt = try #require(reg.estimateCost(provider: .groq, model: "whisper-large-v3-turbo", audioSeconds: 1800))
        #expect(abs(stt - 0.02) < 1e-9)
        #expect(reg.estimateCost(provider: .groq, model: "unknown") == nil)
    }

    @Test func buildsChatForChoice() throws {
        let reg = ProviderRegistry.builtIn
        let g = try reg.makeChat(ProviderChoice(providerID: .groq, model: "m"), secrets: SecretStore(service: "t.\(UUID())"))
        #expect(g.baseURL.absoluteString == "https://api.groq.com/openai/v1")
        #expect(g.profile == .generic)
        let o = try reg.makeChat(ProviderChoice(providerID: .openRouter, model: "m"), secrets: SecretStore(service: "t.\(UUID())"))
        #expect(o.profile.extraBody["provider"] != nil)
        let c = try reg.makeChat(ProviderChoice(providerID: "custom", model: "m", baseURL: "http://127.0.0.1:1234/v1"), secrets: SecretStore(service: "t.\(UUID())"))
        #expect(c.baseURL.host == "127.0.0.1")
        #expect(throws: ChatError.self) { try reg.makeChat(ProviderChoice(providerID: "custom", model: "m"), secrets: SecretStore(service: "t")) }
    }

    @Test func writesSpendRowsAndTotals() async throws {
        let db = try SusuDatabase.inMemory()
        let log = SpendLog(db: db)
        let day = Date(timeIntervalSince1970: 1_790_000_000)   // Sep 2026
        try await log.recordChat(task: "editor", provider: .openRouter, model: "x/y",
                                 usage: Usage(promptTokens: 100, completionTokens: 10, costUSD: 0.002), at: day)
        try await log.recordChat(task: "editor", provider: .groq, model: "llama-3.1-8b-instant",
                                 usage: Usage(promptTokens: 1_000_000, completionTokens: 0), at: day)
        try await log.recordAudio(task: "dictation", provider: .groq, model: "whisper-large-v3-turbo", audioSeconds: 3600, at: day)
        try await log.recordChat(task: "editor", provider: .groq, model: "llama-3.1-8b-instant",
                                 usage: Usage(promptTokens: 5, completionTokens: 5), at: day.addingTimeInterval(86_400 * 60))   // other month
        let rows = try await db.writer.read { try Spend.fetchAll($0) }
        #expect(rows.count == 4)
        let or = try #require(rows.first { $0.provider == "openrouter" })
        #expect(or.costUsd == 0.002 && or.tokensIn == 100 && or.tokensOut == 10 && or.task == "editor")

        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let totals = try await log.monthlyTotals(month: day, calendar: cal)
        #expect(totals.map(\.provider) == ["groq", "openrouter"])
        let groq = totals[0]
        #expect(abs(groq.costUsd - 0.09) < 1e-9)   // 0.05 chat + 0.04 audio
        #expect(groq.operations == 2 && groq.audioSeconds == 3600 && groq.tokensIn == 1_000_000)
        #expect(totals[1].costUsd == 0.002)
    }

    @Test func recordingWrapperLogsEachCall() async throws {
        let db = try SusuDatabase.inMemory()
        let resp = ChatResponse(text: "t", usage: Usage(promptTokens: 10, completionTokens: 2, costUSD: 0.5), model: "m")
        let chat = SpendRecordingChat(FakeChat(result: .success(resp)), provider: .openRouter, log: SpendLog(db: db))
        _ = try await chat.complete(ChatRequest(model: "m", messages: [.user("x")], task: "judge"))
        let rows = try await db.writer.read { try Spend.fetchAll($0) }
        #expect(rows.count == 1 && rows[0].task == "judge" && rows[0].costUsd == 0.5)
    }
}

@Suite struct KeyCheckTests {
    func status(_ reply: StubURLProtocol.Reply, provider: ProviderID = .groq) async -> KeyCheckStatus {
        let base = StubURLProtocol.register(reply)
        let reg = ProviderRegistry(providers: [ProviderInfo(id: provider, displayName: "t", baseURL: base.absoluteString, needsKey: true, prices: [])])
        return await KeyChecker(registry: reg, session: StubURLProtocol.session).check(provider: provider, key: "k")
    }

    @Test func mapsStatuses() async {
        #expect(await status(.http(200, "{}")) == .works)
        #expect(await status(.http(401, "")) == .wrongKey)
        #expect(await status(.http(402, "")) == .noMoney)
        #expect(await status(.fail(.notConnectedToInternet)) == .noNetwork)
        #expect(await status(.fail(.timedOut)) == .noNetwork)
        #expect(await status(.http(500, "")) == .other("HTTP 500"))
    }

    @Test func openRouterUsesKeyEndpoint() async throws {
        let base = StubURLProtocol.register(.http(200, "{}"))
        let reg = ProviderRegistry(providers: [ProviderInfo(id: .openRouter, displayName: "t", baseURL: base.absoluteString, needsKey: true, prices: [])])
        _ = await KeyChecker(registry: reg, session: StubURLProtocol.session).check(provider: .openRouter, key: "k")
        let sent = try #require(StubURLProtocol.requests(for: base).first)
        #expect(sent.request.url?.path == "/v1/key")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test func unknownProvider() async {
        let r = await KeyChecker(registry: ProviderRegistry(providers: []), session: StubURLProtocol.session).check(provider: "zzz", key: "k")
        #expect(r == .other("unknown provider"))
    }
}
