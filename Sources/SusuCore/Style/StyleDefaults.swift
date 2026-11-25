import Foundation

/// The five default styles of spec 3.5 with their rules. Ids are fixed so the Wispr import can address them.
enum StyleDefaults {
    static func make() -> (styles: [Style], rules: [StyleRule]) {
        let t = Date(timeIntervalSince1970: 0)
        func style(_ id: String, _ name: String, _ level: CleanupLevel, voice: Bool = false, isDefault: Bool = false,
                   sort: Int, prompt: String) -> Style {
            Style(id: "style-\(id)", name: name, prompt: prompt, cleanupLevel: level.rawValue, voiceCommands: voice,
                  isDefault: isDefault, sort: sort, updatedAt: t)
        }
        func bundles(_ id: String, _ ids: [String]) -> [StyleRule] {
            ids.map { StyleRule(id: "rule-\(id)-\($0)", styleId: "style-\(id)", kind: "bundle", pattern: $0, updatedAt: t) }
        }
        func urls(_ id: String, _ patterns: [String]) -> [StyleRule] {
            patterns.map { StyleRule(id: "rule-\(id)-url-\($0)", styleId: "style-\(id)", kind: "url", pattern: $0, updatedAt: t) }
        }

        let styles = [
            style("code", "Код", .names, sort: 1, prompt:
                "Пиши слово в слово, как сказано. Ничего не перефразируй и не добавляй. Названия программ, библиотек и команд пиши латиницей, как они пишутся в коде."),
            style("messengers", "Мессенджеры", .normal, sort: 2, prompt:
                "Короткие живые сообщения. Простая пунктуация, без официального тона. Не превращай реплику в длинный текст."),
            style("mail", "Почта", .careful, sort: 3, prompt:
                "Аккуратный письменный текст: полные предложения, абзацы, вежливый тон. Смысл и факты не меняй."),
            style("tasks", "Задачи и заметки", .normal, sort: 4, prompt:
                "Ясные короткие формулировки. Если перечисляешь пункты, оформляй их списком. Даты и имена оставляй как сказано."),
            style("other", "Прочее", .normal, isDefault: true, sort: 5, prompt:
                "Обычный текст: расставь знаки препинания и абзацы, смысл и слова не меняй."),
        ]
        let rules =
            bundles("code", ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.anthropic.claudefordesktop",
                             "com.openai.codex", "com.apple.Terminal", "com.googlecode.iterm2",
                             "com.mitchellh.ghostty", "dev.warp.Warp-Stable"])
            + bundles("messengers", ["ru.keepcoder.Telegram", "net.whatsapp.WhatsApp", "com.tencent.xinWeChat"])
            + bundles("mail", ["com.readdle.SparkDesktop", "com.readdle.smartemail-Mac", "com.apple.mail"])
            + urls("mail", ["mail.google.com/*"])
            + urls("tasks", ["*.bitrix24.*/*"])
            + bundles("tasks", ["notion.id", "com.TickTick.task.mac", "com.apple.Notes"])
        return (styles, rules)
    }
}
