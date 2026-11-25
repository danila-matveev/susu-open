import Testing
@testable import SusuCore

/// Local mode must never reach the cloud recognizer (Codex review 25.11.2026).
@Suite struct STTSelectionTests {
    private struct Stub: SpeechToText {
        let id: ProviderID
        func prewarm() async {}
        func begin(_ options: STTOptions) async throws -> any STTSession { throw STTError.cancelled }
    }
    private let cloud = Stub(id: .groq)
    private let local = Stub(id: .gigaAM)

    @Test func macOnlyUsesLocalEvenWithCloudAvailable() {
        let stt = STTSelection.make(workMode: .macOnly, choice: ProviderChoice(providerID: .groq, model: "x"),
                                    cloud: cloud, local: local)
        #expect(stt.id == .gigaAM)
        #expect(!(stt is STTRouter))
    }

    @Test func localChoiceUsesLocal() {
        let stt = STTSelection.make(workMode: .ownKeys, choice: ProviderChoice(providerID: .gigaAM, model: "x"),
                                    cloud: cloud, local: local)
        #expect(stt.id == .gigaAM)
        #expect(!(stt is STTRouter))
    }

    @Test func macOnlyWithoutModelFailsInsteadOfUsingCloud() async {
        let stt = STTSelection.make(workMode: .macOnly, choice: nil, cloud: cloud, local: nil)
        await #expect(throws: STTError.modelMissing(ProviderID.gigaAM.rawValue)) { _ = try await stt.begin(STTOptions()) }
    }

    @Test func cloudModeKeepsCloudFirst() {
        let stt = STTSelection.make(workMode: .ownKeys, choice: ProviderChoice(providerID: .groq, model: "x"),
                                    cloud: cloud, local: local)
        #expect(stt is STTRouter)
    }
}

@Suite struct CloudPolicyTests {
    @Test func macOnlyAllowsOnlyLocalModels() {
        #expect(!CloudPolicy.allowsLLM(workMode: .macOnly, baseURL: nil))
        #expect(!CloudPolicy.allowsLLM(workMode: .macOnly, baseURL: "https://api.groq.com/openai/v1"))
        #expect(!CloudPolicy.allowsLLM(workMode: .macOnly, baseURL: "https://localhost.evil.example/v1"))
        #expect(CloudPolicy.allowsLLM(workMode: .macOnly, baseURL: "http://localhost:11434/v1"))
        #expect(CloudPolicy.allowsLLM(workMode: .macOnly, baseURL: "http://127.0.0.1:1234/v1"))
    }

    @Test func otherModesAllowCloud() {
        #expect(CloudPolicy.allowsLLM(workMode: .ownKeys, baseURL: nil))
        #expect(CloudPolicy.allowsLLM(workMode: .cloud, baseURL: "https://api.groq.com/openai/v1"))
    }
}
