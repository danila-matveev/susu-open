// «Кому уходит звук и текст» (spec 7): the table, computed live from the current settings.
import Foundation

public struct PrivacyRow: Sendable, Equatable, Identifiable {
    public enum Destination: Sendable, Equatable {
        case viaCloud            // through Susu Cloud, not stored
        case provider(String)    // only the user's own provider
        case nowhere             // feature is off
        case onMac               // processed locally
        case mixedSpeechCloud    // local, cloud only for mixed speech
        case skillService        // the skill's own service
    }
    /// `w1`...`w8`: keys of the row texts in the UI string table.
    public var id: String
    public var destination: Destination
}

public enum PrivacyMap {
    public static func rows(settings s: Settings, registry: ProviderRegistry = .builtIn) -> [PrivacyRow] {
        let mode = s.preferences.workMode
        func dest(_ choice: ProviderChoice?) -> PrivacyRow.Destination {
            guard let c = choice else { return .nowhere }
            switch mode {
            case .macOnly: return .onMac
            case .cloud: return .viaCloud
            case .ownKeys:
                if isLocal(c) { return .onMac }
                return .provider(registry.info(for: c.providerID)?.displayName ?? c.providerID.rawValue)
            }
        }
        let dictation = dest(s.providers.dictation)
        let editor = dest(s.providers.editor)

        let callAudio: PrivacyRow.Destination
        switch mode {
        case .macOnly: callAudio = .onMac
        case .cloud: callAudio = s.preferences.mixedSpeech ? .mixedSpeechCloud : .onMac
        case .ownKeys:
            if let c = s.providers.callsByLanguage, !isLocal(c) {
                callAudio = dest(c)
            } else if s.preferences.mixedSpeech, let m = s.providers.callsMixedSpeech, !isLocal(m) {
                callAudio = .mixedSpeechCloud
            } else {
                callAudio = .onMac
            }
        }
        return [
            PrivacyRow(id: "w1", destination: dictation),
            PrivacyRow(id: "w2", destination: dictation),
            PrivacyRow(id: "w3", destination: editor),
            PrivacyRow(id: "w4", destination: editor),
            PrivacyRow(id: "w5", destination: callAudio),
            PrivacyRow(id: "w6", destination: dest(s.providers.callSummary)),
            PrivacyRow(id: "w7", destination: dest(s.providers.agent)),
            PrivacyRow(id: "w8", destination: .skillService),
        ]
    }

    /// Local engines and addresses on this Mac.
    static func isLocal(_ c: ProviderChoice) -> Bool {
        if c.providerID == .gigaAM || c.providerID == "ollama" { return true }
        guard let address = c.baseURL, let host = URL(string: address)?.host else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
