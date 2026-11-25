// Sample records for previews and screenshots (also used by other screens' visual checks).
import Foundation
import SusuCore

public enum HistorySampleData {
    /// Env switch for dev builds: `SUSU_SEED_SAMPLE=1` fills an empty history on launch.
    public static func seedIfRequested(_ services: AppServices) {
        guard ProcessInfo.processInfo.environment["SUSU_SEED_SAMPLE"] == "1" else { return }
        Task { try? await seed(into: services.history, styles: services.styles) }
    }

    private struct App { let bundle: String; let name: String; let styleId: String?; let window: String; let url: String? }
    private static let apps: [App] = [
        App(bundle: "ru.keepcoder.Telegram", name: "Telegram", styleId: nil, window: "Игорь (поставщик)", url: nil),
        App(bundle: "com.google.Chrome", name: "Chrome", styleId: nil, window: "Календарь — Chrome", url: "calendar.example/week"),
        App(bundle: "bitrix24", name: "Битрикс24", styleId: nil, window: "Задачи — Битрикс24", url: "lumera.bitrix24.example/tasks"),
        App(bundle: "us.zoom.xos", name: "Zoom", styleId: nil, window: "Zoom: чат встречи", url: nil),
        App(bundle: "notion.id", name: "Notion", styleId: nil, window: "Запуск набора — Notion", url: "notion.example/lumera/launch"),
        App(bundle: "com.apple.mail", name: "Почта", styleId: nil, window: "Письмо поставщику", url: nil),
        App(bundle: "com.apple.Notes", name: "Заметки", styleId: nil, window: "Заметки", url: nil),
    ]

    private static let phrases = [
        "Игорь, добрый день! Подтверждаю вторую партию на двадцать седьмое, цену не меняем. Пришли, пожалуйста, обновлённый договор до завтра.",
        "Аня, новый макет коробки мне нравится. Сделай надпись на крышке чуть крупнее и добавь логотип Lumera снизу по центру.",
        "Нужно перенести созвон с поставщиком на четверг, после обеда, и напомнить Игорю про договор.",
        "Идея для карточки товара: сначала размер на модели, потом ткань крупным планом.",
        "Закажи бюджет на октябрь, пожалуйста, и пришли мне итоговую таблицу до конца дня.",
        "Проверь, пожалуйста, остатки по белым комплектам, кажется, там расхождение с вчерашним отчётом.",
        "Планёрка команды в одиннадцать, обсудим запуск набора и макеты упаковки.",
        "Спасибо, всё получила! Завтра отправлю оплату и сразу напишу.",
        "Напомни мне в пятницу позвонить в типографию по поводу тиража.",
        "Добавь в задачу ссылку на макет и поставь срок на понедельник.",
        "Давай созвонимся завтра в три, мне нужно показать новые образцы ткани.",
        "Отправь, пожалуйста, счёт на оплату и акт за ноябрь, бюджет согласован.",
    ]

    /// 45 dictations over three days (today, yesterday, two days ago), varied apps and statuses, three agent
    /// requests, and short audio files for a few of them. Safe to call on an empty store only.
    public static func seed(into history: HistoryStore, styles: StyleStore? = nil, now: Date = Date(),
                            calendar: Calendar = .current) async throws {
        let styleIds = (try? await styles?.styles())?.map(\.id) ?? []
        var rows: [Dictation] = []
        let today = calendar.startOfDay(for: now)
        var n = 0
        for dayBack in 0..<3 {
            let day = calendar.date(byAdding: .day, value: -dayBack, to: today)!
            let count = [17, 15, 13][dayBack]
            for i in 0..<count {
                let app = apps[(n * 3 + i) % apps.count]
                let text = phrases[(n * 5 + i) % phrases.count]
                // Newest first within the day, spread between 09:00 and 18:30 (today: only before now).
                var minutes = 18 * 60 + 30 - i * (570 / count)
                if dayBack == 0 {
                    let nowMin = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
                    minutes = max(5, nowMin - 6 - i * 24)
                }
                let at = calendar.date(byAdding: .minute, value: max(5, minutes), to: day)!
                var d = Dictation(
                    id: "sample-\(n)", createdAt: at, durationMs: 4000 + (n * 937) % 9000, mode: n % 5 == 0 ? .handsfree : .hold,
                    status: .inserted, appName: app.name, bundleId: app.bundle, windowTitle: app.window, url: app.url,
                    sttProvider: "Groq", sttModel: "whisper-large-v3-turbo", editorModel: "Groq · Llama 3.3 70B",
                    rawText: text.lowercased().replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ""),
                    finalText: text, language: "ru", latencyMs: 520 + (n * 131) % 700,
                    audioPath: i % 4 == 0 ? "audio/sample-\(n).wav" : nil, costUsd: 0.0004 + Double(n % 7) * 0.0001)
                if !styleIds.isEmpty { d.styleId = styleIds[(n / 2) % styleIds.count] }
                if n == 2 { d.status = .notInserted }
                if n == 9 { d.status = .failed; d.finalText = nil; d.rawText = nil; d.audioPath = "audio/sample-\(n).wav" }
                if n == 14 { d.status = .cancelled; d.finalText = nil; d.rawText = nil; d.audioPath = "audio/sample-\(n).wav" }
                if n == 21 { d.status = .copiedOnly }
                if n == 5 || n == 27 {
                    d.fallbackUsed = true; d.sttProvider = "GigaAM (на маке)"; d.sttModel = nil
                    d.editorModel = nil; d.costUsd = 0
                }
                if n == 30 { d.editedText = text.replacingOccurrences(of: "пожалуйста, ", with: "") }
                rows.append(d)
                n += 1
            }
        }
        // Agent requests.
        let agents: [(Int, String, String, String, String)] = [
            (1, "Поставь Анастасии задачу: подготовить макеты упаковки к печати, срок пятница",
             "Выделенный текст из Chrome, 340 символов", "Создал задачу «Макеты упаковки к печати» · Анастасия К. · до 13 ноября",
             "lumera.bitrix24.example/task/412"),
            (4, "Что мы решили про сроки поставки?", "Заметки со встречи в Zoom",
             "Ответил: поставка двадцать седьмого, договор до завтра", ""),
            (20, "Перепиши вежливее", "Выделенный текст из Telegram, 120 символов", "Заменил выделенное", ""),
        ]
        for (idx, said, took, did, link) in agents {
            var base = rows[idx]
            base.id = "sample-agent-\(idx)"
            base.kind = .agent; base.rawText = said; base.windowTitle = took; base.finalText = did
            base.url = link.isEmpty ? nil : "https://" + link; base.appName = apps[idx % apps.count].name
            base.audioPath = nil; base.sttModel = nil
            rows[idx] = base
        }
        // Tiny WAV files so «Прослушать» works.
        if let dir = history.baseDirectory?.appendingPathComponent("audio") {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let wav = Self.toneWAV(seconds: 3)
            for r in rows { if let p = r.audioPath { try? wav.write(to: dir.deletingLastPathComponent().appendingPathComponent(p)) } }
        }
        try await history.save(rows)
    }

    /// 16 kHz mono 16-bit sine, a soft 330 Hz beep.
    static func toneWAV(seconds: Int) -> Data {
        let rate = 16_000, count = rate * seconds
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let env = min(1, Double(i) / 800, Double(count - i) / 800)
            let v = Int16(8000 * env * sin(2 * .pi * 330 * Double(i) / Double(rate)))
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> ($0 * 8)) & 0xFF) } }
        func le16(_ v: Int) -> [UInt8] { (0..<2).map { UInt8((v >> ($0 * 8)) & 0xFF) } }
        var h = Data("RIFF".utf8)
        h.append(contentsOf: le32(36 + pcm.count)); h.append(Data("WAVEfmt ".utf8))
        h.append(contentsOf: le32(16)); h.append(contentsOf: le16(1)); h.append(contentsOf: le16(1))
        h.append(contentsOf: le32(rate)); h.append(contentsOf: le32(rate * 2)); h.append(contentsOf: le16(2))
        h.append(contentsOf: le16(16)); h.append(Data("data".utf8)); h.append(contentsOf: le32(pcm.count))
        return h + pcm
    }
}

extension HistoryActions {
    /// Fake hooks for previews and screenshots: retries succeed, compare returns a lightly edited text.
    public static let preview = HistoryActions(
        retry: { _ in .done("Готово") },
        redo: { _ in .done("Переделано") },
        canUndoAgent: { $0.kind == .agent && $0.url != nil },
        wisprFound: true,
        compare: { d, _ in
            try await Task.sleep(for: .milliseconds(900))
            return d.displayText.replacingOccurrences(of: ", пожалуйста,", with: "").replacingOccurrences(of: "пожалуйста, ", with: "")
        })
}
