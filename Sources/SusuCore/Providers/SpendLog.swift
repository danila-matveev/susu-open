// Spend journal (spec 4.3, 5.2 `spend`): every paid operation leaves one row.
import Foundation
import GRDB

public struct SpendLog: Sendable {
    public struct ProviderTotal: Sendable, Equatable {
        public var provider: String
        public var costUsd: Double
        public var tokensIn: Int
        public var tokensOut: Int
        public var audioSeconds: Double
        public var operations: Int
    }

    let db: SusuDatabase
    let registry: ProviderRegistry

    public init(db: SusuDatabase, registry: ProviderRegistry = .builtIn) {
        self.db = db; self.registry = registry
    }

    /// Chat call: cost from `usage.cost`, else the registry price, else 0.
    @discardableResult
    public func recordChat(task: String, provider: ProviderID, model: String, usage: Usage,
                           at: Date = Date()) async throws -> Spend {
        let cost = usage.costUSD ?? registry.estimateCost(provider: provider, model: model,
                                                          tokensIn: usage.promptTokens,
                                                          tokensOut: usage.completionTokens) ?? 0
        return try await save(Spend(at: at, task: task, provider: provider.rawValue, model: model,
                                    tokensIn: usage.promptTokens, tokensOut: usage.completionTokens, costUsd: cost))
    }

    /// Speech-to-text call: cost from the per-hour price (or `costOverride` if the provider reported one).
    @discardableResult
    public func recordAudio(task: String, provider: ProviderID, model: String, audioSeconds: Double,
                            costOverride: Double? = nil, at: Date = Date()) async throws -> Spend {
        let cost = costOverride ?? registry.estimateCost(provider: provider, model: model,
                                                         audioSeconds: audioSeconds) ?? 0
        return try await save(Spend(at: at, task: task, provider: provider.rawValue, model: model,
                                    audioSeconds: audioSeconds, costUsd: cost))
    }

    private func save(_ row: Spend) async throws -> Spend {
        try await db.writer.write { try row.insert($0) }
        return row
    }

    /// Totals per provider for the calendar month containing `month`, biggest first.
    public func monthlyTotals(month: Date = Date(), calendar: Calendar = .current) async throws -> [ProviderTotal] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let from = SusuTime.string(interval.start), to = SusuTime.string(interval.end)
        return try await db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT COALESCE(provider, '') AS provider, SUM(cost_usd) AS cost,
                       COALESCE(SUM(tokens_in), 0) AS tin, COALESCE(SUM(tokens_out), 0) AS tout,
                       COALESCE(SUM(audio_seconds), 0) AS audio, COUNT(*) AS n
                FROM spend WHERE deleted_at IS NULL AND at >= ? AND at < ?
                GROUP BY provider ORDER BY cost DESC, provider
                """, arguments: [from, to]).map {
                ProviderTotal(provider: $0["provider"], costUsd: $0["cost"], tokensIn: $0["tin"],
                              tokensOut: $0["tout"], audioSeconds: $0["audio"], operations: $0["n"])
            }
        }
    }
}

/// Wraps a chat client so every successful call is written to the spend log.
/// Logging failures never break the call.
public struct SpendRecordingChat: ChatLLM {
    let inner: any ChatLLM
    let provider: ProviderID
    let log: SpendLog

    public init(_ inner: any ChatLLM, provider: ProviderID, log: SpendLog) {
        self.inner = inner; self.provider = provider; self.log = log
    }

    public func complete(_ request: ChatRequest) async throws -> ChatResponse {
        let response = try await inner.complete(request)
        _ = try? await log.recordChat(task: request.task, provider: provider, model: request.model, usage: response.usage)
        return response
    }
}
