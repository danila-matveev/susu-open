import Foundation

/// Same meaning as SusuApp's `KeyCheckResult`, plus `other` for everything unexpected.
public enum KeyCheckStatus: Sendable, Equatable {
    case works, wrongKey, noMoney, noNetwork
    case other(String)
}

/// "Check" button: one cheap authenticated GET, no tokens spent.
public struct KeyChecker: Sendable {
    let registry: ProviderRegistry
    let session: URLSession
    let timeout: TimeInterval

    public init(registry: ProviderRegistry = .builtIn, session: URLSession = .shared, timeout: TimeInterval = 8) {
        self.registry = registry; self.session = session; self.timeout = timeout
    }

    /// `baseURL` overrides the registry address (custom provider).
    public func check(provider: ProviderID, key: String, baseURL: String? = nil) async -> KeyCheckStatus {
        guard let base = (baseURL ?? registry.info(for: provider)?.baseURL).flatMap(URL.init(string:)) else {
            return .other("unknown provider")
        }
        // OpenRouter's /models is public, so it would accept any key: /key needs a real one.
        let path = provider == .openRouter ? "key" : "models"
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.timeoutInterval = timeout
        req.setValue("Susu/\(Susu.version)", forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .other("not an HTTP response") }
            switch http.statusCode {
            case 200..<300: return .works
            case 401, 403: return .wrongKey
            case 402: return .noMoney
            default: return .other("HTTP \(http.statusCode)")
            }
        } catch {
            switch ChatError.from(error) {
            case .noNetwork, .timeout: return .noNetwork
            default: return .other(error.localizedDescription)
            }
        }
    }
}
