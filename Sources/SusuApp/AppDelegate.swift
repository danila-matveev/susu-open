// Susu menu-bar app. No Dock icon (LSUIElement + .accessory policy).
import AppKit
import SusuCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    let services: AppServices

    public init(services: AppServices) {
        self.services = services
        super.init()
    }
    private lazy var shell = ShellController(services: services)
    private lazy var dictation = DictationService(services: services)
    private var pasteLastItem: NSMenuItem?
    private var pill: PillController?
    private var importObserver: NSObjectProtocol?
    private let toast = ToastController()
    private var openItem: NSMenuItem?
    private var settingsItem: NSMenuItem?
    private var quitItem: NSMenuItem?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.glyph()
        item.button?.setAccessibilityLabel("Susu")
        let menu = NSMenu()
        let version = NSMenuItem(title: "Susu \(Susu.version)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(.separator())
        let pasteLast = NSMenuItem(title: "", action: #selector(pasteLastDictation), keyEquivalent: "")
        pasteLast.target = self
        menu.addItem(pasteLast)
        pasteLastItem = pasteLast
        let open = NSMenuItem(title: "", action: #selector(openMain), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: "", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        openItem = open; settingsItem = settings; quitItem = quit
        menu.delegate = self
        retitleMenu()
        item.menu = menu
        statusItem = item

        installEditMenu()
        let services = self.services
        Task { try? await services.styles.seedDefaultsIfEmpty() }
        installPill()
        SectionRouter.historyActions = HistoryActions.live(
            services: services,
            pasteAgain: { [weak self] d in
                if let t = d.editedText ?? d.finalText { self?.dictation.paste(t) }
            },
            importFromWispr: { NotificationCenter.default.post(name: .susuOpenWisprImport, object: nil) })
        SectionRouter.stylePreviewing = { raw, style in
            let r = await DictationService.cleanup(raw, style: style, context: nil, services: services)
            return StylePreviewResult(text: r.text, usedEditor: r.editorModel != nil, editorLabel: r.editorModel, pressEnter: r.pressEnter)
        }
        dictation.start()
        let hooks = OnboardingHooks.live(services: services)
        OnboardingController.showIfNeeded(services: services, hooks: hooks) { [weak self] in self?.shell.showMain() }
        importObserver = NotificationCenter.default.addObserver(forName: .susuOpenWisprImport, object: nil, queue: .main) { [services] _ in
            MainActor.assumeIsolated { OnboardingController.showWisprImport(services: services, hooks: hooks) }
        }
        // Audio older than the retention setting is deleted at launch (spec 5.1).
        Task { [services] in
            _ = try? await AudioRetention.run(days: services.settings.current.audioRetentionDays,
                                              in: services.dataDirectory, database: services.database)
        }

        // Dev/test hooks: open a window at launch.
        let env = ProcessInfo.processInfo.environment
        if env["SUSU_OPEN_MAIN"] == "1" { shell.showMain() }
        if env["SUSU_OPEN_SETTINGS"] == "1" { shell.showSettings() }
    }

    @objc private func openMain() { shell.showMain() }
    @objc private func pasteLastDictation() { dictation.pasteLast() }

    private func installPill() {
        let pill = PillController()
        pill.attach(toast)
        pill.language = shell.model.language
        let settings = services.settings
        pill.soundsEnabled = { settings.current.soundsEnabled }
        pill.onHandsFreeDone = { [weak self] in self?.dictation.finishHandsFree() }
        pill.onHandsFreeCancel = { [weak self] in self?.dictation.cancelHandsFree() }
        pill.onOpenSettings = { [weak self] in self?.shell.showSettings() }
        pill.onOpenHistory = { [weak self] in self?.shell.showMain() }
        var menu = PillMenuHandlers()
        menu.pasteLast = { [weak self] in self?.dictation.pasteLast() }
        menu.openHistory = { [weak self] in self?.shell.showMain() }
        menu.openSettings = { [weak self] in self?.shell.showSettings() }
        menu.hideForHour = { [weak pill] in pill?.hide(for: 3600) }
        pill.menuActions = menu
        dictation.onEvent = { [weak pill] in pill?.handle($0) }
        dictation.onKeyName = { [weak pill] in pill?.setKeyName($0) }
        dictation.onNoteEvent = { [weak self, weak pill] e in
            guard let self, let pill else { return }
            switch e {
            case .listening: pill.setState(.noteListening)
            case .inserted:
                pill.setState(.idle)
                self.toast.show(.noteSaved(language: pill.language) { [weak self] in self?.shell.showMain(.notes) })
            default: pill.handle(e)
            }
        }
        NotesBridge.shared.startVoiceNote = { [weak self] in self?.dictation.startVoiceNote() }
        let dictionary = services.dictionary
        dictation.onLearned = { [weak self, weak pill] entries in
            guard let self, let pill else { return }
            self.toast.show(.remembered(EditWatcher.fact(entries), language: pill.language) {
                Task { for e in entries { try? await dictionary.softDelete(id: e.id) } }
            })
        }
        dictation.onCopied = { [weak self, weak pill] in
            guard let self, let pill else { return }
            self.toast.show(.copied(language: pill.language))
        }
        self.pill = pill
    }

    /// Accessory apps still need an Edit menu, or Cmd+C / Cmd+V do nothing in text fields.
    private func installEditMenu() {
        let lang = shell.model.language
        let t = { L10n.string($0, language: lang) }
        let edit = NSMenu(title: t("menu.edit"))
        edit.addItem(withTitle: t("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: t("menu.redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: t("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: t("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: t("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: t("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let main = NSMenu()
        main.addItem(NSMenuItem())   // app menu slot
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
    @objc private func openSettings() { shell.showSettings() }

    // Menu titles are AppKit strings: refresh them each time the menu opens so a language switch shows up.
    public func menuNeedsUpdate(_ menu: NSMenu) { retitleMenu() }

    private func retitleMenu() {
        let lang = shell.model.language
        pasteLastItem?.title = L10n.string("menu.pasteLast", language: lang)
        openItem?.title = L10n.string("menu.open", language: lang)
        settingsItem?.title = L10n.string("menu.settings", language: lang)
        quitItem?.title = L10n.string("menu.quit", language: lang)
    }

    /// Template glyph from docs/DESIGN.md: two rounded bars of different height, 18 pt.
    static func glyph() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 5, y: 5, width: 3, height: 8), xRadius: 1.5, yRadius: 1.5).fill()
            NSBezierPath(roundedRect: NSRect(x: 10, y: 2.5, width: 3, height: 13), xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

public enum SusuAppMain {
    @MainActor public static func run() {
        let app = NSApplication.shared
        let services: AppServices
        do { services = try AppServices() } catch {
            // The data folder or database cannot be opened. Nothing was changed or deleted:
            // say so, point at the folder and quit, instead of crashing without a word.
            app.setActivationPolicy(.regular)
            app.activate(ignoringOtherApps: true)
            let folder = SettingsStore.defaultDirectory()
            let ru = Locale.preferredLanguages.first?.hasPrefix("ru") ?? false
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = ru ? "Susu не может открыть свои данные" : "Susu cannot open its data"
            alert.informativeText = (ru
                ? "Ничего не удалено. Папка с данными:\n\(folder.path)\n\nОшибка: \(error)"
                : "Nothing was deleted. Data folder:\n\(folder.path)\n\nError: \(error)")
            alert.addButton(withTitle: ru ? "Показать папку" : "Show folder")
            alert.addButton(withTitle: ru ? "Выйти" : "Quit")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            exit(1)
        }
        let delegate = AppDelegate(services: services)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
