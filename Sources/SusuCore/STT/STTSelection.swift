import Foundation

/// Which recognizer a dictation uses (mandate, section 5: local mode sends nothing outside).
public enum STTSelection {
    /// - "Mac only" work mode, or the on-device model chosen for dictation: local model only, no cloud fallback.
    /// - Otherwise: cloud first, the local model as offline fallback when it is installed.
    public static func make(workMode: WorkMode, choice: ProviderChoice?,
                            cloud: any SpeechToText, local: (any SpeechToText)?) -> any SpeechToText {
        if workMode == .macOnly || choice?.providerID == .gigaAM {
            return local ?? LocalModelMissingSTT()
        }
        return STTRouter(primary: cloud, fallbacks: local.map { [$0] } ?? [])
    }
}

/// Local-only was asked for but no model is installed: fail loudly instead of quietly using the cloud.
public struct LocalModelMissingSTT: SpeechToText {
    public let id = ProviderID.gigaAM
    public init() {}
    public func prewarm() async {}
    public func begin(_ options: STTOptions) async throws -> any STTSession {
        throw STTError.modelMissing(ProviderID.gigaAM.rawValue)
    }
}

/// "Mac only" covers the whole pipeline, not just recognition: text goes to a language model
/// only when that model runs on this Mac (Ollama, LM Studio on localhost).
public enum CloudPolicy {
    public static func allowsLLM(workMode: WorkMode, baseURL: String?) -> Bool {
        guard workMode == .macOnly else { return true }
        guard let host = baseURL.flatMap({ URL(string: $0) })?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
