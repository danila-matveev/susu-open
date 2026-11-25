import Testing
@testable import SusuCore

@Suite struct DataExportPrivacyTests {
    func dest(_ s: Settings, _ id: String) -> PrivacyRow.Destination {
        PrivacyMap.rows(settings: s).first { $0.id == id }!.destination
    }

    @Test func ownKeysFollowsChosenProviders() {
        var s = Settings()
        s.providers.editor = ProviderChoice(providerID: .openRouter, model: "m")
        #expect(dest(s, "w1") == .provider("Groq"))
        #expect(dest(s, "w3") == .provider("OpenRouter"))
        #expect(dest(s, "w6") == .nowhere)  // summary not set
        #expect(dest(s, "w5") == .onMac)
        #expect(dest(s, "w8") == .skillService)
    }

    @Test func localChoicesAndMixedSpeech() {
        var s = Settings()
        s.providers.dictation = ProviderChoice(providerID: .gigaAM, model: "g")
        s.providers.agent = ProviderChoice(providerID: "custom", model: "m", baseURL: "http://localhost:1234/v1")
        s.providers.callsMixedSpeech = ProviderChoice(providerID: .openRouter, model: "q")
        #expect(dest(s, "w1") == .onMac)
        #expect(dest(s, "w7") == .onMac)
        #expect(dest(s, "w5") == .mixedSpeechCloud)
        s.preferences.mixedSpeech = false
        #expect(dest(s, "w5") == .onMac)
    }

    @Test func modesOverride() {
        var s = Settings()
        s.preferences.workMode = .macOnly
        #expect(dest(s, "w1") == .onMac)
        s.preferences.workMode = .cloud
        #expect(dest(s, "w1") == .viaCloud)
    }
}
