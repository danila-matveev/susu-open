// Snapshot tests of the M3 screens (docs/BUILD-PLAN.md, «Тестирование», row «Интерфейс»).
// Every screen is rendered through NSHostingView over synthetic data in a throwaway data folder and a
// throwaway Keychain service, in light and dark, RU (and EN for a few). References live in __Snapshots__/.
//
// Skipped when env CI is set: GitHub's macos-15 runner has an older OS and Swift 6.1, and text and
// controls rasterise differently there, so references recorded on a Mac with the newer OS would fail.
// Run locally: `swift test --filter SusuAppSnapshotTests`. To refresh references delete the PNG (or set
// SNAPSHOT_TESTING_RECORD=all) and run once; a first run with a missing reference "fails" by design.
import AppKit
import SnapshotTesting
import SusuCore
import SwiftUI
import XCTest
@testable import SusuApp

@MainActor
final class ScreenSnapshotTests: XCTestCase {
    /// Pinned "now": 18 Nov 2026, 19:00 local. Rows are built relative to it, screens read it through AppClock.
    nonisolated static let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 18; c.hour = 19; c.minute = 0
        return Calendar.current.date(from: c)!
    }()

    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil,
                      "Snapshots are recorded on the dev Mac; CI renders differently (older OS and Swift).")
        AppClock.fixed = Self.now
        AppClock.fixedFirstName = "Анна"
    }

    override func tearDown() async throws {
        AppClock.fixed = nil
        AppClock.fixedFirstName = nil
    }

    // MARK: Harness

    private func world(_ lang: InterfaceLanguage, dark: Bool,
                       seed: ((AppServices) async throws -> Void)? = nil) async throws -> ShellModel {
        // Fixed path (the data screen prints it); always empty at the start, never the real data folder.
        let dir = URL(fileURLWithPath: "/tmp/susu-snapshot-data", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        // Own empty Keychain service: the screens must never see (or touch) the real keys.
        let services = try AppServices(directory: dir, secrets: SecretStore(service: "app.susu.snapshot-tests"))
        _ = try services.settings.update { $0.interfaceLanguage = lang; $0.theme = dark ? .dark : .light }
        try await seed?(services)
        return ShellModel(services: services)
    }

    private func shot<V: View>(_ name: String, _ size: CGSize, dark: Bool, settle: Double = 0.8,
                               precision: Float = 0.98, _ view: V) async throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.appearance = appearance
        host.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Screens load their data in .task; give them time to finish.
        try await Task.sleep(for: .seconds(settle))
        host.layoutSubtreeIfNeeded()
        assertSnapshot(of: host, as: .image(precision: precision, perceptualPrecision: 0.98),
                       named: name, testName: "screens")
        withExtendedLifetime(window) {}
    }

    /// One screen over the given variants: (language, dark).
    private func variants(_ name: String, _ size: CGSize, _ list: [(InterfaceLanguage, Bool)],
                          background: Color = Palette.bgCard, settle: Double = 0.8,
                          seed: ((AppServices) async throws -> Void)? = nil,
                          _ make: (ShellModel) -> some View) async throws {
        for (lang, dark) in list {
            let model = try await world(lang, dark: dark, seed: seed)
            let view = make(model).shellRoot(model).background(background)
            try await shot("\(name)-\(lang == .ru ? "ru" : "en")-\(dark ? "dark" : "light")", size, dark: dark,
                           settle: settle, view)
        }
    }

    private static let ruBoth: [(InterfaceLanguage, Bool)] = [(.ru, false), (.ru, true)]
    private static let ruBothEnLight: [(InterfaceLanguage, Bool)] = [(.ru, false), (.ru, true), (.en, false)]

    // MARK: Shell and main sections

    func testShell() async throws {
        let seed: (AppServices) async throws -> Void = { s in
            try await HistorySampleData.seed(into: s.history, styles: s.styles, now: Self.now)
        }
        for (lang, dark) in Self.ruBoth {
            let model = try await world(lang, dark: dark, seed: seed)
            try await shot("shell-history-\(lang == .ru ? "ru" : "en")-\(dark ? "dark" : "light")", Metrics.mainWindowSize,
                           dark: dark, settle: 1.2, MainWindowView().shellRoot(model).environment(\.historyActions, .preview))
        }
    }

    func testHistory() async throws {
        let seed: (AppServices) async throws -> Void = { s in
            try await HistorySampleData.seed(into: s.history, styles: s.styles, now: Self.now)
        }
        try await variants("history", CGSize(width: 1000, height: 760), Self.ruBothEnLight, background: Palette.bg,
                           settle: 1.2, seed: seed) { _ in ContentCard { HistoryScreen() }.environment(\.historyActions, .preview) }
    }

    func testHistoryEmpty() async throws {
        try await variants("history-empty", CGSize(width: 1000, height: 600), [(.ru, false), (.ru, true)], background: Palette.bg) { _ in
            ContentCard { HistoryScreen() }.environment(\.historyActions, HistoryActions(wisprFound: true))
        }
    }

    func testDictionary() async throws {
        let seed: (AppServices) async throws -> Void = { s in
            let d = s.dictionary
            for w in ["Lumera", "Susu", "Битрикс24", "GigaAM", "Игорь Петров"] {
                _ = try await d.add(kind: "word", phrase: w, starred: w == "Lumera", now: Self.now)
            }
            _ = try await d.add(kind: "replacement", phrase: "люмир", replacement: "Lumera", now: Self.now)
            _ = try await d.add(kind: "replacement", phrase: "суси", replacement: "Susu", now: Self.now)
        }
        try await variants("dictionary", CGSize(width: 950, height: 700), Self.ruBothEnLight, seed: seed) { _ in DictionaryScreen() }
    }

    func testDictionaryEmpty() async throws {
        try await variants("dictionary-empty", CGSize(width: 950, height: 600), [(.ru, false), (.ru, true)]) { _ in DictionaryScreen() }
    }

    /// The header alone, with a tight tolerance: at the full-screen 0.98 a whole header button fits inside
    /// the allowed difference, so `testDictionary` did not notice «Импорт» being added.
    func testDictionaryHeader() async throws {
        for (lang, dark) in Self.ruBothEnLight {
            let model = try await world(lang, dark: dark) { s in
                _ = try await s.dictionary.add(kind: "word", phrase: "Susu", now: Self.now)
            }
            // Full-height screen, then only its top 120 pt (a plain 120-high frame would centre the content).
            let top = DictionaryScreen().shellRoot(model).background(Palette.bgCard)
                .frame(width: 950, height: 700)
                .frame(width: 950, height: 120, alignment: .top).clipped()
            try await shot("dictionary-header-\(lang == .ru ? "ru" : "en")-\(dark ? "dark" : "light")",
                           CGSize(width: 950, height: 120), dark: dark, precision: 0.999, top)
        }
    }

    func testDictionaryImportSheet() async throws {
        for (lang, dark) in Self.ruBothEnLight {
            let model = try await world(lang, dark: dark)
            let sheet = SheetFrame(onDismiss: {}) {
                ImportSheet(services: model.services, lang: lang, close: {}, finish: { _ in })
            }
            try await shot("dictionary-import-\(lang == .ru ? "ru" : "en")-\(dark ? "dark" : "light")",
                           CGSize(width: 560, height: 440), dark: dark, precision: 0.995,
                           sheet.shellRoot(model).background(Palette.bgCard))
        }
    }

    func testSnippets() async throws {
        let seed: (AppServices) async throws -> Void = { s in
            _ = try await s.dictionary.add(kind: "snippet", phrase: "мой адрес", replacement: "Москва, ул. Тверская, 1", now: Self.now)
            _ = try await s.dictionary.add(kind: "snippet", phrase: "подпись", replacement: "С уважением, Анна", now: Self.now)
            _ = try await s.dictionary.add(kind: "snippet", phrase: "ссылка на макет", replacement: "https://example.com/mockup", now: Self.now)
        }
        try await variants("snippets", CGSize(width: 950, height: 700), Self.ruBothEnLight, seed: seed) { _ in SnippetsScreen() }
    }

    func testStyles() async throws {
        // The default styles are created by the screen itself on first load.
        try await variants("styles", CGSize(width: 950, height: 780), Self.ruBothEnLight) { _ in StylesScreen() }
    }

    func testStats() async throws {
        let seed: (AppServices) async throws -> Void = { s in
            let cal = Calendar.current
            var rows: [Dictation] = []
            let apps: [(String, String)] = [("com.todesktop.230313mzl4w4u92", "Cursor"), ("ru.keepcoder.Telegram", "Telegram"),
                                            ("com.google.Chrome", "Chrome"), ("notion.id", "Notion")]
            for day in 0..<40 where day % 7 != 3 {
                for n in 0..<(2 + (day * 5) % 9) {
                    let t = cal.date(byAdding: .minute, value: -(day * 1440 + n * 37), to: Self.now) ?? Self.now
                    let a = apps[(day + n) % apps.count]
                    rows.append(Dictation(id: "stat-\(day)-\(n)", createdAt: t, durationMs: 4000 + n * 700, appName: a.1, bundleId: a.0,
                                          rawText: "раз два три четыре пять шесть семь восемь", latencyMs: 380 + (day * 37 + n * 11) % 260))
                }
            }
            try await s.history.save(rows)
            _ = try await s.spend.recordAudio(task: "stt", provider: .groq, model: "whisper-large-v3-turbo", audioSeconds: 3600 * 4)
            _ = try await s.spend.recordChat(task: "edit", provider: .openRouter, model: "x",
                                             usage: Usage(promptTokens: 1_000_000, completionTokens: 100_000, costUSD: 0.62))
        }
        try await variants("stats", CGSize(width: 950, height: 900), Self.ruBothEnLight, seed: seed, { _ in StatsScreen() })
    }

    func testStatsEmpty() async throws {
        try await variants("stats-empty", CGSize(width: 950, height: 600), [(.ru, false)]) { _ in StatsScreen() }
    }

    func testNotes() async throws {
        let seed: (AppServices) async throws -> Void = { s in
            let n = NotesStore(database: s.database, baseDirectory: s.dataDirectory)
            _ = try await n.create(title: "Идея для упаковки", text: "На внутренней стороне коробки напечатать короткую инструкцию по уходу.",
                                   tags: ["упаковка", "идеи"], origin: "hotkey", now: Self.now)
            _ = try await n.create(title: "Вопросы Игорю по образцам", text: "Спросить Игоря про сроки пошива образца.",
                                   tags: ["поставки"], origin: "agent", now: Self.now.addingTimeInterval(-3600))
        }
        try await variants("notes", CGSize(width: 1100, height: 760), Self.ruBothEnLight, seed: seed) { _ in NotesScreen() }
    }

    func testNotesEmpty() async throws {
        try await variants("notes-empty", CGSize(width: 1100, height: 600), [(.ru, false), (.ru, true)]) { _ in NotesScreen() }
    }

    // MARK: Settings

    func testSettingsWindow() async throws {
        for (lang, dark) in Self.ruBoth {
            let model = try await world(lang, dark: dark)
            model.settingsSection = .keys
            try await shot("window-keys-\(lang == .ru ? "ru" : "en")-\(dark ? "dark" : "light")", Metrics.settingsWindowSize,
                           dark: dark, SettingsWindowView().shellRoot(model))
        }
    }

    func testSettingsSections() async throws {
        // Microphone is left out on purpose: it lists the audio devices of the machine it runs on.
        let sections: [(SettingsSection, CGFloat)] = [(.keys, 640), (.lang, 640), (.models, 700), (.calls, 700),
                                                      (.agent, 700), (.account, 520), (.data, 900), (.misc, 600)]
        for (section, height) in sections {
            let list = section == .keys || section == .models || section == .data ? Self.ruBothEnLight : Self.ruBoth
            try await variants("settings-\(section.rawValue)", CGSize(width: 700, height: height), list) { _ in
                SectionRouter.view(for: section)
            }
        }
    }

    // MARK: Onboarding

    private func onboarding(_ lang: InterfaceLanguage, dark: Bool, name: String,
                            configure: (OnboardingModel) -> Void) async throws {
        let model = try await world(lang, dark: dark)
        let system = OnboardingSystem(micPermission: { .notDetermined }, requestMic: { false }, axTrusted: { false },
                                      promptAX: {}, open: { _ in }, wisprFolderExists: { true })
        let onb = OnboardingModel(services: model.services, hooks: OnboardingHooks(), system: system)
        onb.phraseIndex = 0
        configure(onb)
        try await shot("onboarding-\(name)-\(lang == .ru ? "ru" : "en")-\(dark ? "dark" : "light")",
                       CGSize(width: 560, height: 720), dark: dark, OnboardingView(model: onb).shellRoot(model))
    }

    func testOnboarding() async throws {
        let preview = WisprPreview(dictations: 1840, audioFiles: 1200, vocabulary: 96, styleGroups: 3, calls: 12, notes: 7,
                                   neededBytes: 2_400_000_000, freeBytes: 80_000_000_000)
        let steps: [(String, (OnboardingModel) -> Void)] = [
            ("permissions", { $0.step = .permissions }),
            ("how", { $0.step = .how }),
            ("how-mac", { $0.step = .how; $0.choice = .mac }),
            ("trial", { $0.step = .trial }),
            ("trial-ok", { $0.step = .trial; $0.trialText = "Привет, это моя первая диктовка." }),
            ("wispr", { $0.step = .wispr; $0.wispr = .found }),
            ("wispr-dry", { $0.step = .wispr; $0.wispr = .dry(preview) }),
            ("finish", { $0.step = .finish }),
        ]
        for (name, configure) in steps {
            for (lang, dark) in Self.ruBoth { try await onboarding(lang, dark: dark, name: name, configure: configure) }
        }
        try await onboarding(.en, dark: false, name: "how", configure: { $0.step = .how })
        try await onboarding(.en, dark: false, name: "trial", configure: { $0.step = .trial })
    }

    // MARK: Pill and toasts

    func testPillStates() async throws {
        let states: [(String, PillState, Bool)] = [
            ("idle", .idle, false), ("hover", .hover, false), ("listen-pending", .listening(confirmed: false), false),
            ("listen", .listening(confirmed: true), false), ("hands", .handsFree, false), ("processing", .processing, false),
            ("agent", .agentListening, false), ("agent-working", .agentWorking, false), ("agent-waiting", .agentWaiting, false),
            ("note", .noteListening, false), ("call", .idle, true), ("call-listen", .listening(confirmed: true), true),
            ("error", .error, false),
        ]
        for (lang, dark) in [(InterfaceLanguage.ru, false), (.ru, true), (.en, false)] {
            for (name, state, callDot) in states where lang == .ru || name == "hands" {
                let model = PillModel()
                model.language = lang
                model.callDot = callDot
                model.state = state
                let bg = dark ? Color(white: 0.1) : Color(white: 0.93)
                // The wave breathes with the clock, so allow a little more drift than for static screens.
                try await shot("pill-\(name)-\(lang == .ru ? "ru" : "en")-\(dark ? "dark" : "light")", PillMetrics.panelSize,
                               dark: dark, settle: 0.3, precision: 0.97, PillView(model: model).background(bg))
            }
        }
    }

    func testToasts() async throws {
        let l = InterfaceLanguage.ru
        let toasts: [(String, Toast)] = [
            ("copied", .copied(language: l)),
            ("notpasted", .notPasted(language: l) {}),
            ("micsilent", .micSilent(language: l, retry: {}, chooseMicrophone: {})),
            ("nokey", .noKey(provider: "Groq", language: l) {}),
            ("remembered", .remembered("Анастасия — маркетолог", language: l) {}),
            ("limit19", .limit19(language: l)),
        ]
        for (name, toast) in toasts {
            for dark in [false, true] {
                let model = ToastModel()
                model.toast = toast
                model.visible = true
                let bg = dark ? Color(white: 0.1) : Color(white: 0.93)
                try await shot("toast-\(name)-ru-\(dark ? "dark" : "light")", CGSize(width: 420, height: 200), dark: dark,
                               settle: 0.3, ToastView(model: model).background(bg))
            }
        }
    }
}
