import Foundation

/// Pattern lists for `CleanupRules` (spec 3.4 step 1 and 3, spec 3.3 hallucinations).
/// All patterns are ICU regex fragments, matched case-insensitively.
enum RulesLists {
    /// Filler sounds, whole words only. Single "м" is deliberately absent (it is "metre").
    /// "мм"/"mm" are skipped after a digit (see `Rules.fillerRegex`), so "10 мм" survives.
    static let fillers: [String] = [
        "э+", "э(?:-э)+", "эм+", "мм+", "м(?:-м)+",
        "uh+", "um+", "erm+", "er", "ehm", "hm+", "mm+",
    ]

    /// Whisper hallucinations on silence. Each entry must be a whole sentence at the very end of the text.
    /// Entries ending in `.{0,100}` swallow a credited name ("Субтитры сделал DimaTorzok").
    static let hallucinations: [String] = [
        // Russian
        "продолжение\\s+следует",
        "спасибо\\s+за\\s+просмотр",
        "спасибо\\s+за\\s+просмотр\\s+и\\s+до\\s+новых\\s+встреч",
        "подписывайтесь\\s+на\\s+(?:наш\\s+)?канал",
        "не\\s+забудьте\\s+подписаться(?:\\s+на\\s+(?:наш\\s+)?канал)?",
        "ставьте\\s+лайки?",
        "приятного\\s+просмотра",
        "субтитры\\s+(?:сделал|создавал|подогнал|делал|сделаны|подготовил)\\b.{0,100}",
        "субтитры\\s+предоставлены\\b.{0,100}",
        "редактор\\s+субтитров\\b.{0,100}",
        "корректор\\b.{0,60}",
        "дима\\s*торзок\\b.{0,60}",
        // English
        "thanks\\s+for\\s+watching",
        "thank\\s+you\\s+for\\s+watching",
        "thank\\s+you\\s+for\\s+watching\\s+this\\s+video",
        "please\\s+subscribe(?:\\s+to\\s+(?:my|our|the)\\s+channel)?",
        "don'?t\\s+forget\\s+to\\s+(?:like\\s+and\\s+)?subscribe",
        "like\\s+and\\s+subscribe",
        "see\\s+you\\s+in\\s+the\\s+next\\s+(?:video|one)",
        "subtitles\\s+by\\b.{0,100}",
        "transcribed\\s+by\\b.{0,100}",
    ]

    /// Spoken "press Enter" commands, only honoured at the very end of the text.
    static let voiceCommands: [String] = [
        "нажми(?:те)?\\s+(?:enter|энтер|ентер|ввод)",
        "отправь(?:те)?",
        "press\\s+enter",
        "hit\\s+enter",
        "send\\s+it",
    ]
}
