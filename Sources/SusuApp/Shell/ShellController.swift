// Owns the two windows (main, settings). Opening a window activates the app: the policy stays
// .accessory (no Dock icon), but windows still come to the front.
import AppKit
import Combine
import SwiftUI
import SusuCore

@MainActor
public final class ShellController: NSObject {
    public let model: ShellModel
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    public init(services: AppServices) {
        model = ShellModel(services: services)
        super.init()
        model.openSettings = { [weak self] section in self?.showSettings(section) }
        model.openMain = { [weak self] section in self?.showMain(section) }
        // Theme: set the app-wide appearance so every window (including other screens' own) follows it.
        model.$theme.sink { theme in
            switch theme {
            case .system: NSApp.appearance = nil
            case .light: NSApp.appearance = NSAppearance(named: .aqua)
            case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
            }
        }.store(in: &cancellables)
        // Window titles are AppKit strings: retitle when the interface language changes.
        model.$language.sink { [weak self] _ in self?.retitle() }.store(in: &cancellables)
    }

    public func showMain(_ section: MainSection? = nil) {
        if let section { model.mainSection = section }
        if mainWindow == nil {
            mainWindow = makeWindow(
                size: Metrics.mainWindowSize, minSize: Metrics.mainWindowMinSize, resizable: true,
                root: MainWindowView().shellRoot(model), autosave: "SusuMainWindow")
        }
        present(mainWindow)
        retitle()
    }

    public func showSettings(_ section: SettingsSection? = nil) {
        if let section { model.settingsSection = section }
        if settingsWindow == nil {
            settingsWindow = makeWindow(
                size: Metrics.settingsWindowSize, minSize: Metrics.settingsWindowSize, resizable: false,
                root: SettingsWindowView().shellRoot(model), autosave: nil)
        }
        present(settingsWindow)
        retitle()
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func retitle() {
        let lang = model.language
        mainWindow?.title = "Susu"
        settingsWindow?.title = L10n.string("nav.settings", language: lang)
    }

    private func makeWindow<Root: View>(size: CGSize, minSize: CGSize, resizable: Bool, root: Root, autosave: String?) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if resizable { style.formUnion([.resizable, .miniaturizable]) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []   // the window size is ours, not the content's ideal size
        window.contentView = hosting
        window.contentMinSize = minSize
        window.setContentSize(size)
        window.center()
        if let autosave { window.setFrameAutosaveName(autosave) }
        return window
    }
}
