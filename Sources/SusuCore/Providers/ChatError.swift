import Foundation

/// Failure of a chat-completion call. Mirrors `STTError` so the UI can treat both the same way.
public enum ChatError: Error, Equatable, Sendable {
    case noNetwork
    case unauthorized          // 401/403
    case outOfCredit           // 402
    case rateLimited           // 429
    case timeout
    case http(Int, String)
    case badResponse(String)
    case cancelled

    /// Errors after which a second provider is worth trying (spec 4.3).
    public var allowsFallback: Bool {
        switch self {
        case .unauthorized, .outOfCredit, .rateLimited, .timeout, .noNetwork: return true
        case .http(let code, _): return code >= 500
        case .badResponse, .cancelled: return false
        }
    }

    static func from(status: Int, body: String) -> ChatError {
        switch status {
        case 401, 403: return .unauthorized
        case 402: return .outOfCredit
        case 429: return .rateLimited
        default: return .http(status, String(body.prefix(300)))
        }
    }

    static func from(_ error: Error) -> ChatError {
        if let e = error as? ChatError { return e }
        if error is CancellationError { return .cancelled }
        if let u = error as? URLError {
            switch u.code {
            case .timedOut: return .timeout
            case .cancelled: return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                return .noNetwork
            default: return .http(u.errorCode, u.localizedDescription)
            }
        }
        return .badResponse(error.localizedDescription)
    }
}
