// Toast model and the ready-made toasts from docs/design/ux-map.md (TOAST.*) with the texts of the approved prototype.
import Foundation
import SusuCore

public struct ToastAction {
    public var title: String
    /// Light-on-dark button (the main answer); others are quiet.
    public var isPrimary: Bool
    public var handler: @MainActor () -> Void
    public init(_ title: String, isPrimary: Bool = false, handler: @escaping @MainActor () -> Void = {}) {
        self.title = title; self.isPrimary = isPrimary; self.handler = handler
    }
}

public struct Toast {
    public enum Kind: Sendable { case info, error, success }

    public var kind: Kind
    /// Bold first line.
    public var text: String
    /// Quieter second line.
    public var detail: String?
    /// Underlined text link under the text (up to the buttons).
    public var link: ToastAction?
    /// At most two buttons are drawn from the spec; the layout wraps if there are more.
    public var actions: [ToastAction]
    /// SF Symbol; the default depends on `kind`.
    public var icon: String?
    /// Seconds; nil = 3 s without buttons, 10 s with buttons.
    public var duration: TimeInterval?
    /// Error toasts give the pill a brick hairline (default: only for `.error`).
    public var pillError: Bool

    public init(kind: Kind, text: String, detail: String? = nil, link: ToastAction? = nil,
                actions: [ToastAction] = [], icon: String? = nil, duration: TimeInterval? = nil, pillError: Bool? = nil) {
        self.kind = kind; self.text = text; self.detail = detail; self.link = link
        self.actions = actions; self.icon = icon; self.duration = duration
        self.pillError = pillError ?? (kind == .error)
    }

    var resolvedDuration: TimeInterval { duration ?? (actions.isEmpty && link == nil ? 3 : 10) }
    var resolvedIcon: String {
        icon ?? { switch kind { case .info: "info.circle"; case .error: "exclamationmark.triangle"; case .success: "checkmark" } }()
    }
}

// MARK: ready-made toasts

private func s(_ key: String, _ l: InterfaceLanguage) -> String { PillL10n.string(key, l) }

extension Toast {
    private static func close(_ l: InterfaceLanguage) -> ToastAction { ToastAction(s("toast.close", l)) }

    /// TOAST.copied: «Скопировано» (1.5 s).
    public static func copied(language l: InterfaceLanguage = .system) -> Toast {
        Toast(kind: .success, text: s("toast.copied", l), duration: 1.5)
    }
    /// TOAST.window-changed: «Скопировано — вставь ⌘V».
    public static func windowChanged(language l: InterfaceLanguage = .system) -> Toast {
        Toast(kind: .info, text: s("toast.windowChanged", l), icon: "doc.on.doc")
    }
    /// TOAST.not-pasted: «Не вставилось — ⌃⌘V» + [Вставить] [Закрыть].
    public static func notPasted(language l: InterfaceLanguage = .system, paste: @escaping @MainActor () -> Void) -> Toast {
        Toast(kind: .error, text: s("toast.notPasted", l),
              actions: [ToastAction(s("toast.paste", l), isPrimary: true, handler: paste), close(l)])
    }
    /// TOAST.secure-input: «Сейчас диктовка недоступна» (password field).
    public static func secureInput(language l: InterfaceLanguage = .system) -> Toast {
        Toast(kind: .info, text: s("toast.secureInput", l), icon: "exclamationmark.triangle", pillError: false)
    }
    /// TOAST.mic-silent: no sound for 5 s. [Закрыть] [Попробовать ещё] and the link «Выбрать микрофон».
    public static func micSilent(language l: InterfaceLanguage = .system,
                                 retry: @escaping @MainActor () -> Void, chooseMicrophone: @escaping @MainActor () -> Void) -> Toast {
        Toast(kind: .error, text: s("toast.micSilent.title", l), detail: s("toast.micSilent.text", l),
              link: ToastAction(s("toast.chooseMic", l), handler: chooseMicrophone),
              actions: [close(l), ToastAction(s("toast.retry", l), isPrimary: true, handler: retry)])
    }
    /// TOAST.no-fallback: no network and no local model. [Закрыть] [Открыть историю].
    public static func noNetwork(language l: InterfaceLanguage = .system, openHistory: @escaping @MainActor () -> Void) -> Toast {
        Toast(kind: .error, text: s("toast.noNetwork", l),
              actions: [close(l), ToastAction(s("toast.openHistory", l), handler: openHistory)])
    }
    /// TOAST.no-key: «Нужен ключ Groq, чтобы диктовать».
    public static func noKey(provider: String, language l: InterfaceLanguage = .system, openSettings: @escaping @MainActor () -> Void) -> Toast {
        Toast(kind: .error, text: PillL10n.format("toast.noKey", l, provider),
              actions: [ToastAction(s("toast.openSettings", l), isPrimary: true, handler: openSettings), close(l)])
    }
    /// TOAST.key-invalid.
    public static func keyInvalid(language l: InterfaceLanguage = .system, openSettings: @escaping @MainActor () -> Void) -> Toast {
        Toast(kind: .error, text: s("toast.keyInvalid", l),
              actions: [ToastAction(s("toast.openSettings", l), isPrimary: true, handler: openSettings), close(l)])
    }
    /// TOAST.no-money: the provider account is empty.
    public static func noMoney(language l: InterfaceLanguage = .system, openSettings: @escaping @MainActor () -> Void) -> Toast {
        Toast(kind: .error, text: s("toast.noMoney", l),
              actions: [ToastAction(s("toast.openSettings", l), isPrimary: true, handler: openSettings), close(l)])
    }
    /// TOAST.no-last: «Пока нечего вставлять».
    public static func noLast(language l: InterfaceLanguage = .system) -> Toast {
        Toast(kind: .info, text: s("toast.noLast", l), icon: "clock")
    }
    /// TOAST.note-saved with [Открыть].
    public static func noteSaved(language l: InterfaceLanguage = .system, open: @escaping @MainActor () -> Void) -> Toast {
        Toast(kind: .info, text: s("toast.noteSaved", l), actions: [ToastAction(s("toast.open", l), handler: open)],
              icon: "doc.text", duration: 4)
    }
    /// PILL.limit-19: «Осталась 1 минута записи» (3 s, no buttons).
    public static func limit19(language l: InterfaceLanguage = .system) -> Toast {
        Toast(kind: .info, text: s("toast.limit19", l), icon: "clock")
    }
    /// «Запомнил: X · Отменить».
    public static func remembered(_ fact: String, language l: InterfaceLanguage = .system, undo: @escaping @MainActor () -> Void) -> Toast {
        Toast(kind: .success, text: PillL10n.format("toast.remembered", l, fact),
              actions: [ToastAction(s("toast.undo", l), handler: undo)], duration: 6)
    }
    /// TOAST.cloud-limit-words.
    public static func cloudLimitWords(language l: InterfaceLanguage = .system, openAccount: @escaping @MainActor () -> Void) -> Toast {
        Toast(kind: .error, text: s("toast.cloudLimitWords.title", l), detail: s("toast.cloudLimitWords.text", l),
              actions: [ToastAction(s("toast.openAccount", l), isPrimary: true, handler: openAccount), close(l)])
    }
    /// TOAST.cloud-unreachable (3 s).
    public static func cloudUnreachable(language l: InterfaceLanguage = .system) -> Toast {
        Toast(kind: .error, text: s("toast.cloudUnreachable", l), actions: [close(l)], duration: 3)
    }
    /// TOAST.no-perm-mic.
    public static func noMicrophonePermission(language l: InterfaceLanguage = .system, openSettings: @escaping @MainActor () -> Void) -> Toast {
        Toast(kind: .error, text: s("toast.noPermMic", l),
              actions: [ToastAction(s("toast.openSettings", l), isPrimary: true, handler: openSettings), close(l)])
    }
    /// TOAST.no-perm-ax: Accessibility is off.
    public static func noAccessibilityPermission(language l: InterfaceLanguage = .system, openSettings: @escaping @MainActor () -> Void) -> Toast {
        Toast(kind: .error, text: s("toast.noPermAX.title", l), detail: s("toast.noPermAX.text", l),
              actions: [ToastAction(s("toast.openSettings", l), isPrimary: true, handler: openSettings), close(l)])
    }
    /// TOAST.agent-error: «Не получилось: <причина>» + «Успел: <что сделано>» + [Закрыть] [Попробовать ещё].
    public static func agentError(reason: String, done: String, language l: InterfaceLanguage = .system,
                                  retry: @escaping @MainActor () -> Void) -> Toast {
        Toast(kind: .error, text: PillL10n.format("toast.agentError.title", l, reason),
              detail: PillL10n.format("toast.agentError.text", l, done),
              actions: [close(l), ToastAction(s("toast.retry", l), isPrimary: true, handler: retry)])
    }
}
