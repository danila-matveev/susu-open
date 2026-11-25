// Title and tags for a note from one short request to the editor model (spec 1.6).
// Without a model, or when the answer is unusable, the title is the first words of the text.
import Foundation

public struct NoteTitle: Sendable, Equatable {
    public var title: String
    public var tags: [String]
    public init(title: String, tags: [String] = []) { self.title = title; self.tags = tags }
}

public struct NoteTitler: Sendable {
    public static let maxTitleWords = 6
    public static let maxTags = 3

    let llm: (any ChatLLM)?
    let model: String

    /// `llm == nil` means "no key / no model": titles come from the first words.
    public init(llm: (any ChatLLM)?, model: String) {
        self.llm = llm
        self.model = model
    }

    static let schemaJSON = """
        {"type":"object","properties":{"title":{"type":"string"},"tags":{"type":"array","items":{"type":"string"}}},\
        "required":["title","tags"],"additionalProperties":false}
        """

    static let prompt = """
        You name voice notes. Reply with JSON only: {"title": "...", "tags": ["..."]}. \
        The title has at most 6 words, no quotes, no final period, in the language of the note. \
        Give at most 3 short lowercase tags (one word each, same language), only if they clearly fit.
        """

    /// Never throws: any failure gives the fallback title and no tags.
    public func title(for text: String) async -> NoteTitle {
        let fallback = NoteTitle(title: Self.fallbackTitle(text))
        guard let llm else { return fallback }
        let request = ChatRequest(
            model: model,
            messages: [.system(Self.prompt), .user(String(text.prefix(4000)))],
            jsonSchema: (name: "note_title", schemaJSON: Self.schemaJSON),
            temperature: 0.2, maxTokens: 120, timeout: 8, task: "editor")
        guard let response = try? await llm.complete(request), let parsed = Self.parse(response.text) else { return fallback }
        return parsed
    }

    /// First words of the text, at most 6.
    public static func fallbackTitle(_ text: String) -> String {
        clip(text.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }

    /// Reads the model's JSON (also inside a code fence). nil if there is no usable title.
    public static func parse(_ raw: String) -> NoteTitle? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawTitle = obj["title"] as? String else { return nil }
        let title = clip(rawTitle.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        guard !title.isEmpty else { return nil }
        var tags: [String] = []
        for t in (obj["tags"] as? [Any] ?? []).compactMap({ $0 as? String }) {
            let tag = t.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines)).lowercased()
            if !tag.isEmpty, tag.count <= 24, !tags.contains(tag) { tags.append(tag) }
            if tags.count == maxTags { break }
        }
        return NoteTitle(title: title, tags: tags)
    }

    private static func clip(_ words: [String]) -> String {
        var s = words.prefix(maxTitleWords).joined(separator: " ")
        let junk = CharacterSet(charactersIn: "\"«»“”'.,;:!?…—-").union(.whitespacesAndNewlines)
        s = s.trimmingCharacters(in: junk)
        return s
    }
}
