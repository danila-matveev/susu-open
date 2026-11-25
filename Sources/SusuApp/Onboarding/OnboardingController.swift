// The first-run wizard window: 560 wide, shown once (until settings has `onboardingDone`).
import AppKit
import SwiftUI
import SusuCore

@MainActor
public final class OnboardingController: NSObject, NSWindowDelegate {
    private static var current: OnboardingController?

    private let services: AppServices
    private let model: OnboardingModel
    private let shell: ShellModel
    private var window: NSWindow?
    private var openHistory: () -> Void

    /// Shows the wizard when the first run is not done yet. `openHistory` opens the main window on «Главная».
    public static func showIfNeeded(services: AppServices, hooks: OnboardingHooks = OnboardingHooks(),
                                    openHistory: @escaping () -> Void = {}) {
        guard !services.settings.current.onboardingDone, current == nil else { return }
        show(services: services, hooks: hooks, system: .live, openHistory: openHistory)
    }

    /// Settings → «Импорт…»: the same Wispr step on its own.
    public static func showWisprImport(services: AppServices, hooks: OnboardingHooks) {
        guard current == nil else { current?.window?.makeKeyAndOrderFront(nil); return }
        show(services: services, hooks: hooks, system: .live, start: .wispr)
    }

    static func show(services: AppServices, hooks: OnboardingHooks, system: OnboardingSystem,
                     start: OnboardingModel.Step = .permissions, configure: (OnboardingModel) -> Void = { _ in },
                     openHistory: @escaping () -> Void = {}) {
        let c = OnboardingController(services: services, hooks: hooks, system: system, openHistory: openHistory)
        c.model.step = start
        configure(c.model)
        current = c
        c.present()
    }

    private init(services: AppServices, hooks: OnboardingHooks, system: OnboardingSystem, openHistory: @escaping () -> Void) {
        self.services = services
        self.openHistory = openHistory
        model = OnboardingModel(services: services, hooks: hooks, system: system)
        shell = ShellModel(services: services)
        super.init()
        model.onFinish = { [weak self] open in self?.close(openHistory: open) }
    }

    private func present() {
        let size = CGSize(width: 560, height: 720)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.title = "Susu"
        w.delegate = self
        let host = NSHostingView(rootView: OnboardingView(model: model).shellRoot(shell))
        host.sizingOptions = []
        w.contentView = host
        w.setContentSize(size)
        w.center()
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    private func close(openHistory open: Bool) {
        if open { openHistory() }
        window?.close()
    }

    /// Closing the window at any point counts as done: the wizard never nags twice.
    public func windowWillClose(_ notification: Notification) {
        _ = try? services.settings.update { $0.onboardingDone = true }
        Self.current = nil
    }
}
