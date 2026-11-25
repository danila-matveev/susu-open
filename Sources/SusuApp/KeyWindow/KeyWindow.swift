// Temporary "Groq key" window (T1.5). Replaced by the Models settings section later.
#if os(macOS)
import AppKit
import SwiftUI
import SusuCore

public enum KeyCheckResult: Sendable, Equatable {
    case works, wrongKey, noMoney, noNetwork
}

@MainActor
final class KeyWindowModel: ObservableObject {
    enum Status: Equatable { case idle, checking, result(KeyCheckResult), saved, saveFailed }

    @Published var key = ""
    @Published var status = Status.idle
    let provider: ProviderID
    let secrets: SecretStore
    let check: @Sendable (String) async -> KeyCheckResult

    init(provider: ProviderID, secrets: SecretStore, check: @escaping @Sendable (String) async -> KeyCheckResult) {
        self.provider = provider
        self.secrets = secrets
        self.check = check
        key = (try? secrets.get(provider)) ?? ""
    }

    var trimmed: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    func runCheck() {
        let value = trimmed
        guard !value.isEmpty else { return }
        status = .checking
        let check = check
        Task {
            let result = await check(value)
            self.status = .result(result)
        }
    }

    func save() {
        do {
            if trimmed.isEmpty { try secrets.delete(provider) } else { try secrets.set(trimmed, for: provider) }
            status = .saved
        } catch {
            status = .saveFailed
        }
    }
}

struct KeyWindowView: View {
    @ObservedObject var model: KeyWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("keywindow.title", bundle: .module).font(.headline)
            Text("keywindow.hint", bundle: .module).font(.callout).foregroundStyle(.secondary)
            SecureField(text: $model.key) { Text("keywindow.field", bundle: .module) }
                .textFieldStyle(.roundedBorder)
            HStack {
                Button { model.runCheck() } label: { Text("keywindow.check", bundle: .module) }
                    .disabled(model.trimmed.isEmpty || model.status == .checking)
                Button { model.save() } label: { Text("keywindow.save", bundle: .module) }
                    .keyboardShortcut(.defaultAction)
                statusText.font(.callout)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    @ViewBuilder private var statusText: some View {
        switch model.status {
        case .idle: EmptyView()
        case .checking: Text("keywindow.checking", bundle: .module).foregroundStyle(.secondary)
        case .saved: Text("keywindow.saved", bundle: .module).foregroundStyle(.green)
        case .saveFailed: Text("keywindow.saveFailed", bundle: .module).foregroundStyle(.red)
        case .result(.works): Text("keywindow.works", bundle: .module).foregroundStyle(.green)
        case .result(.wrongKey): Text("keywindow.wrongKey", bundle: .module).foregroundStyle(.red)
        case .result(.noMoney): Text("keywindow.noMoney", bundle: .module).foregroundStyle(.orange)
        case .result(.noNetwork): Text("keywindow.noNetwork", bundle: .module).foregroundStyle(.orange)
        }
    }
}

@MainActor
public enum KeyWindowController {
    private static var window: NSWindow?

    /// Opens (or focuses) the key window. `check` does the real request; it is injected so tests and previews need no network.
    public static func show(
        provider: ProviderID = .groq,
        secrets: SecretStore = SecretStore(),
        check: @escaping @Sendable (String) async -> KeyCheckResult
    ) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = KeyWindowModel(provider: provider, secrets: secrets, check: check)
        let controller = NSHostingController(rootView: KeyWindowView(model: model))
        let w = NSWindow(contentViewController: controller)
        w.title = String(localized: "keywindow.windowTitle", bundle: .module)
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { KeyWindowController.window = nil }
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
