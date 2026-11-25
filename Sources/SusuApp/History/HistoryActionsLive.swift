// Real implementations of the History screen hooks: retry (re-recognize saved audio), redo (re-run the
// editor on the saved text) and compare (try another model / style without touching history).
import Foundation
import SusuCore

extension HistoryActions {
    /// `compareOptions` stays nil: the screen then builds the model list from the provider registry and the
    /// style list from its own cache; a missing key shows up as `CompareNoKeyError` from `compare`.
    @MainActor
    static func live(
        services s: AppServices,
        pasteAgain: @escaping @MainActor @Sendable (Dictation) -> Void,
        importFromWispr: @escaping @MainActor @Sendable () -> Void
    ) -> HistoryActions {
        let lang = { s.settings.current.interfaceLanguage }
        let failed = { HL.string("hist.cmp.err.generic", lang()) }

        return HistoryActions(
            retry: { d in
                // Not inserted but the text exists: just insert it again.
                if d.hasText, d.status == .notInserted || d.status == .copiedOnly {
                    pasteAgain(d)
                    return .done()
                }
                guard let file = s.history.audioURL(for: d) else { return .done(HL.string("hist.audio.gone", lang())) }
                let groq = OpenAICompatibleTranscription.groq(keyProvider: {
                    (try? s.secrets.get(.groq)) ?? ProcessInfo.processInfo.environment["GROQ_API_KEY"]
                })
                let terms = (try? await s.dictionary.hintTerms()) ?? []
                let hint = STTHintBuilder.build(terms: terms.map { HintTerm($0) }, windowTitle: d.windowTitle,
                                                leadIn: DictationService.leadIn)
                let raw: String
                do {
                    let segments = try await groq.transcribe(
                        file, options: FileSTTOptions(language: s.settings.current.dictationLanguage.languageMode, hint: hint))
                    raw = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    DictationService.log.error("history retry STT failed: \(String(describing: error), privacy: .public)")
                    return .done(failed())
                }
                guard !raw.isEmpty else { return .done(failed()) }
                let cleaned = await DictationService.cleanup(raw, context: d.context, services: s)
                let model = groq.model
                _ = try? await s.history.update(id: d.id) { r in
                    r.rawText = raw
                    r.finalText = cleaned.text
                    r.editedText = nil
                    r.sttProvider = ProviderID.groq.rawValue
                    r.sttModel = model
                    r.styleId = cleaned.styleId ?? r.styleId
                    r.editorModel = cleaned.editorModel
                    r.costUsd = cleaned.costUSD
                    // Recognized now, but nothing was pasted anywhere.
                    if r.status == .failed || r.status == .cancelled { r.status = .notInserted }
                }
                return .done()
            },
            redo: { d in
                guard let raw = d.rawText ?? d.finalText, !raw.isEmpty else { return .done(failed()) }
                let cleaned = await DictationService.cleanup(raw, context: d.context, services: s)
                _ = try? await s.history.update(id: d.id) { r in
                    r.finalText = cleaned.text
                    r.editedText = nil
                    r.styleId = cleaned.styleId ?? r.styleId
                    r.editorModel = cleaned.editorModel
                    r.costUsd = cleaned.costUSD
                }
                return .done()
            },
            pasteAgain: pasteAgain,
            importFromWispr: importFromWispr,
            compare: { d, choice in
                let current = s.settings.current.providers.editor ?? DictationService.defaultEditor
                let target = resolveModel(choice.modelID, current: current, registry: s.registry)
                let envName = target.providerID == .groq ? "GROQ_API_KEY" : "OPENROUTER_API_KEY"
                let hasKey = ((try? s.secrets.get(target.providerID)) ?? nil) != nil
                    || ProcessInfo.processInfo.environment[envName] != nil
                guard hasKey else { throw CompareNoKeyError(model: target.model) }

                let styles = (try? await s.styles.styles()) ?? []
                let style = styles.first { $0.id == (choice.styleID ?? d.styleId) }
                let replacements = ((try? await s.dictionary.replacements()) ?? []).map {
                    RulesEntry(phrase: $0.phrase, replacement: $0.replacement)
                }
                let level = style?.level ?? .normal
                let source = d.rawText ?? d.finalText ?? ""
                let step1 = CleanupRules.apply(source, options: RulesOptions(
                    replacements: replacements, capitalize: level != .verbatim))
                let result = await Editor.edit(
                    text: step1.text, level: level,
                    context: EditorContext(app: d.appName, styleRule: style?.prompt),
                    terms: (try? await s.dictionary.hintTerms()) ?? [],
                    chat: DictationService.editorChat(target, secrets: s.secrets, registry: s.registry),
                    model: target.model, timeout: 20)
                if case .failed = result.outcome { throw CompareFailed() }
                return result.text
            })
    }

    private struct CompareFailed: Error {}

    /// Compare option ids are "provider/model" for registry rows; anything else is the record's own editor model.
    static func resolveModel(_ id: String?, current: ProviderChoice, registry: ProviderRegistry) -> ProviderChoice {
        guard let id, !id.isEmpty else { return current }
        for p in registry.providers where p.prices.contains(where: { $0.inputPerMTok != nil }) {
            let prefix = p.id.rawValue + "/"
            if id.hasPrefix(prefix) { return ProviderChoice(providerID: p.id, model: String(id.dropFirst(prefix.count))) }
        }
        return ProviderChoice(providerID: current.providerID, model: id, baseURL: current.baseURL)
    }
}

private extension Dictation {
    /// Enough of the original context for style resolution (app, window, url); no text from the screen.
    var context: ContextSnapshot? {
        guard appName != nil || bundleId != nil else { return nil }
        return ContextSnapshot(appName: appName, bundleID: bundleId, windowTitle: windowTitle, url: url)
    }
}
