// Built-in providers and their prices (spec 4.2, 4.3). A new provider = one row here.
import Foundation

public struct ModelPrice: Sendable, Equatable {
    public var model: String
    /// USD per 1M input / output tokens (chat models).
    public var inputPerMTok: Double?
    public var outputPerMTok: Double?
    /// USD per hour of audio (speech-to-text models).
    public var audioPerHour: Double?
    public init(_ model: String, input: Double? = nil, output: Double? = nil, audioHour: Double? = nil) {
        self.model = model; inputPerMTok = input; outputPerMTok = output; audioPerHour = audioHour
    }
}

public struct ProviderInfo: Sendable, Equatable {
    public var id: ProviderID
    public var displayName: String
    public var baseURL: String
    public var needsKey: Bool
    public var prices: [ModelPrice]
}

public struct ProviderRegistry: Sendable {
    public var providers: [ProviderInfo]

    public init(providers: [ProviderInfo]) { self.providers = providers }

    public func info(for id: ProviderID) -> ProviderInfo? { providers.first { $0.id == id } }

    // Prices below are APPROXIMATE, as of 11.2026, from public price lists. They are only a fallback:
    // OpenRouter reports the real cost in `usage.cost`, which always wins. Refresh before release.
    public static let builtIn = ProviderRegistry(providers: [
        ProviderInfo(id: .groq, displayName: "Groq", baseURL: "https://api.groq.com/openai/v1", needsKey: true, prices: [
            ModelPrice("whisper-large-v3-turbo", audioHour: 0.04),
            ModelPrice("whisper-large-v3", audioHour: 0.111),
            ModelPrice("llama-3.1-8b-instant", input: 0.05, output: 0.08),
            ModelPrice("llama-3.3-70b-versatile", input: 0.59, output: 0.79),
            ModelPrice("openai/gpt-oss-20b", input: 0.075, output: 0.30),
            ModelPrice("openai/gpt-oss-120b", input: 0.15, output: 0.60),
        ]),
        ProviderInfo(id: .openRouter, displayName: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", needsKey: true, prices: [
            ModelPrice("openai/gpt-oss-120b", input: 0.15, output: 0.60),
            ModelPrice("google/gemini-2.5-flash", input: 0.30, output: 2.50),
            ModelPrice("anthropic/claude-haiku-4.5", input: 1.00, output: 5.00),
        ]),
        ProviderInfo(id: "openai", displayName: "OpenAI", baseURL: "https://api.openai.com/v1", needsKey: true, prices: [
            ModelPrice("whisper-1", audioHour: 0.36),
            ModelPrice("gpt-4o-mini-transcribe", audioHour: 0.18),
        ]),
        ProviderInfo(id: "ollama", displayName: "Ollama", baseURL: "http://localhost:11434/v1", needsKey: false, prices: []),
        ProviderInfo(id: "custom", displayName: "Custom", baseURL: "", needsKey: false, prices: []),
    ])

    /// Estimated cost in USD, nil when the provider/model has no price in the registry.
    public func estimateCost(provider: ProviderID, model: String, tokensIn: Int = 0, tokensOut: Int = 0,
                             audioSeconds: Double = 0) -> Double? {
        guard let price = info(for: provider)?.prices.first(where: { $0.model == model }) else { return nil }
        var cost = 0.0
        var priced = false
        if let a = price.audioPerHour { cost += audioSeconds / 3600 * a; priced = true }
        if let i = price.inputPerMTok { cost += Double(tokensIn) / 1_000_000 * i; priced = true }
        if let o = price.outputPerMTok { cost += Double(tokensOut) / 1_000_000 * o; priced = true }
        return priced ? cost : nil
    }

    /// Builds the chat client for one row of the Models table. Key is read from the Keychain on every call,
    /// so a key saved in settings works without restart (Р9).
    public func makeChat(_ choice: ProviderChoice, secrets: SecretStore, session: URLSession = .shared) throws -> OpenAICompatibleChat {
        guard let address = choice.baseURL ?? info(for: choice.providerID)?.baseURL,
              !address.isEmpty, let url = URL(string: address) else {
            throw ChatError.badResponse("no address for provider \(choice.providerID)")
        }
        let id = choice.providerID
        return OpenAICompatibleChat(
            baseURL: url,
            apiKey: { (try? secrets.get(id)) ?? nil },
            profile: id == .openRouter ? .openRouter() : .generic,
            session: session)
    }
}
