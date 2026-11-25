import Foundation

/// Tries the primary provider, and on a "provider problem" error quietly asks the secondary (spec 4.3).
public struct FallbackChat: ChatLLM {
    public struct Result: Sendable, Equatable {
        public var response: ChatResponse
        /// True when the secondary answered; history marks it (`fallback_used`).
        public var usedFallback: Bool
        /// Why the primary failed, when `usedFallback`.
        public var primaryError: ChatError?
    }

    let primary: any ChatLLM
    let secondary: (any ChatLLM)?
    /// Model to use on the secondary (its provider usually has different model names).
    let secondaryModel: String?

    public init(primary: any ChatLLM, secondary: (any ChatLLM)?, secondaryModel: String? = nil) {
        self.primary = primary; self.secondary = secondary; self.secondaryModel = secondaryModel
    }

    public func complete(_ request: ChatRequest) async throws -> ChatResponse {
        try await completeReporting(request).response
    }

    public func completeReporting(_ request: ChatRequest) async throws -> Result {
        do {
            return Result(response: try await primary.complete(request), usedFallback: false, primaryError: nil)
        } catch {
            let e = ChatError.from(error)
            guard e.allowsFallback, let secondary else { throw e }
            var second = request
            if let secondaryModel { second.model = secondaryModel }
            return Result(response: try await secondary.complete(second), usedFallback: true, primaryError: e)
        }
    }
}
