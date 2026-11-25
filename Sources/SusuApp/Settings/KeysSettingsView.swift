// «Клавиши»: record a shortcut (click Change, press the combo or a lone modifier), hold and double-press timing.
import AppKit
import SwiftUI
import SusuCore

extension Notification.Name {
    /// Posted with `userInfo["active": Bool]` while a shortcut is being recorded, so the global hotkey tap can pause.
    public static let susuShortcutRecording = Notification.Name("susu.shortcutRecording")
}

/// Pure helpers for shortcut text and key codes.
enum ShortcutText {
    static let keyNames: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc", 122: "F1", 120: "F2", 99: "F3", 118: "F4",
        96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
        107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// Device key codes of single modifier keys.
    static let modifierCodes: [Int: ModifierKey] = [
        59: .leftControl, 62: .rightControl, 58: .leftOption, 61: .rightOption, 55: .leftCommand,
        54: .rightCommand, 56: .leftShift, 60: .rightShift, 63: .fn,
    ]

    static func modifierToken(_ m: HotkeyModifier) -> String {
        switch m {
        case .control: "⌃ Ctrl"
        case .option: "⌥ Option"
        case .shift: "⇧ Shift"
        case .command: "⌘ Cmd"
        }
    }

    static func modifierKeyToken(_ k: ModifierKey, rightWord: String) -> String {
        switch k {
        case .leftControl: "⌃ Ctrl"
        case .rightControl: "\(rightWord) ⌃"
        case .leftOption: "⌥ Option"
        case .rightOption: "\(rightWord) ⌥"
        case .leftCommand: "⌘ Cmd"
        case .rightCommand: "\(rightWord) ⌘"
        case .leftShift: "⇧ Shift"
        case .rightShift: "\(rightWord) ⇧"
        case .fn: "fn"
        }
    }

    static func tokens(_ s: HotkeySetting, rightWord: String) -> [String] {
        if let k = s.modifierKey { return [modifierKeyToken(k, rightWord: rightWord)] }
        let order: [HotkeyModifier] = [.control, .option, .shift, .command]
        var out = order.filter { s.modifiers.contains($0) }.map(modifierToken)
        if let code = s.keyCode { out.append(keyNames[code] ?? "#\(code)") }
        return out
    }

    static func normalized(_ s: HotkeySetting) -> HotkeySetting {
        let order: [HotkeyModifier] = [.control, .option, .shift, .command]
        var n = s
        n.modifiers = order.filter { s.modifiers.contains($0) }
        return n
    }
}

/// Listens for the next combination while recording. Local monitor: works only while a Susu window is key.
@MainActor
final class ShortcutCapture: ObservableObject {
    @Published private(set) var recordingID: String?
    @Published private(set) var liveTokens: [String] = []
    private var monitor: Any?
    private var down = Set<Int>()
    private var seen = Set<Int>()
    private var usedKey = false
    private var onCommit: ((String, HotkeySetting) -> Void)?
    var rightWord = "right"

    func start(id: String, onCommit: @escaping (String, HotkeySetting) -> Void) {
        stop()
        recordingID = id
        self.onCommit = onCommit
        down = []; seen = []; usedKey = false; liveTokens = []
        NotificationCenter.default.post(name: .susuShortcutRecording, object: nil, userInfo: ["active": true])
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let type = event.type, code = Int(event.keyCode), flags = event.modifierFlags, again = event.isARepeat
            let consumed = MainActor.assumeIsolated { self.handle(type: type, code: code, flags: flags, isRepeat: again) }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recordingID != nil {
            NotificationCenter.default.post(name: .susuShortcutRecording, object: nil, userInfo: ["active": false])
        }
        recordingID = nil; onCommit = nil; liveTokens = []
    }

    private func mods(_ f: NSEvent.ModifierFlags) -> [HotkeyModifier] {
        var m: [HotkeyModifier] = []
        if f.contains(.control) { m.append(.control) }
        if f.contains(.option) { m.append(.option) }
        if f.contains(.shift) { m.append(.shift) }
        if f.contains(.command) { m.append(.command) }
        return m
    }

    private func commit(_ s: HotkeySetting) {
        guard let id = recordingID, let cb = onCommit else { return }
        stop()
        cb(id, ShortcutText.normalized(s))
    }

    /// Returns true when the event is consumed.
    private func handle(type: NSEvent.EventType, code: Int, flags rawFlags: NSEvent.ModifierFlags, isRepeat: Bool) -> Bool {
        guard recordingID != nil else { return false }
        switch type {
        case .keyDown:
            if isRepeat { return true }
            let flags = rawFlags.intersection([.control, .option, .shift, .command])
            if code == 53 && flags.isEmpty { stop(); return true }
            usedKey = true
            commit(HotkeySetting(keyCode: code, modifiers: mods(flags)))
            return true
        case .flagsChanged:
            guard ShortcutText.modifierCodes[code] != nil else { return false }
            if down.contains(code) { down.remove(code) } else { down.insert(code); seen.insert(code) }
            liveTokens = seen.compactMap { ShortcutText.modifierCodes[$0] }
                .map { ShortcutText.modifierKeyToken($0, rightWord: rightWord) }.sorted()
            if down.isEmpty {
                if !usedKey, seen.count == 1, let k = ShortcutText.modifierCodes[seen.first!] {
                    commit(.modifier(k))
                } else {
                    seen = []; liveTokens = []
                }
            }
            return false
        default: return false
        }
    }
}

private struct ShortcutAction: Identifiable {
    let id: String
    let titleKey: String
    let detailKey: String
    let keyPath: WritableKeyPath<HotkeySettings, HotkeySetting>?  // nil: shown, not editable (double press of dictation key)
}

@MainActor private let shortcutActions: [ShortcutAction] = [
    .init(id: "dictation", titleKey: "k.dictate", detailKey: "k.dictate.d", keyPath: \.dictation),
    .init(id: "doubleTap", titleKey: "k.hd", detailKey: "k.hd.d", keyPath: nil),
    .init(id: "hands", titleKey: "k.hands", detailKey: "k.hands.d", keyPath: \.handsFreeChord),
    .init(id: "paste", titleKey: "k.paste", detailKey: "k.paste.d", keyPath: \.pasteLast),
    .init(id: "copy", titleKey: "k.copy", detailKey: "k.copy.d", keyPath: \.copyLast),
    .init(id: "agent", titleKey: "k.agent", detailKey: "k.agent.d", keyPath: \.agent),
    .init(id: "note", titleKey: "k.note", detailKey: "k.note.d", keyPath: \.notes),
    .init(id: "call", titleKey: "k.call", detailKey: "k.call.d", keyPath: \.callRecording),
]

public struct KeysSettingsView: View {
    public init() {}
    public var body: some View { LiveHost { live, model in KeysContent(live: live, model: model) } }
}

private struct KeysContent: View {
    @ObservedObject var live: SettingsLive
    @ObservedObject var model: ShellModel
    @StateObject private var capture = ShortcutCapture()
    @State private var pending: (actionID: String, setting: HotkeySetting, otherID: String)?

    private var right: String { tr("k.right", model.language) }

    var body: some View {
        SettingsPage(section: .keys, lead: "k.lead") {
            SGroup(first: true) {
                ForEach(shortcutActions) { a in
                    row(a)
                    if let p = pending, p.actionID == a.id { conflictRow(p) }
                    if a.id == "hands", live.value.hotkeys.handsFreeChord == .chord(49, [.control]) {
                        SNote("k.cs") {
                            SBtn("k.cs.btn", size: .small) { openSystemSettings("x-apple.systempreferences:com.apple.Keyboard-Settings.extension") }
                        }
                    }
                }
            }
            SGroup(title: "k.thr") {
                SRow("k.hold", detail: "k.hold.d") {
                    SStepper(value: live.binding(\.hotkeys.holdThreshold), range: 0.1...1.0, step: 0.05, locale: model.locale, unit: tr("unit.s", model.language))
                }
                SRow("k.dbl", detail: "k.dbl.d") {
                    SStepper(value: live.binding(\.hotkeys.doubleTapWindow), range: 0.15...1.0, step: 0.05, locale: model.locale, unit: tr("unit.s", model.language))
                }
            }
        }
        .onAppear { capture.rightWord = right }
        .onDisappear { capture.stop() }
    }

    private func setting(_ a: ShortcutAction) -> HotkeySetting {
        if let kp = a.keyPath { return live.value.hotkeys[keyPath: kp] }
        return live.value.hotkeys.dictation
    }

    private func row(_ a: ShortcutAction) -> some View {
        let recording = capture.recordingID == a.id
        let tokens = ShortcutText.tokens(setting(a), rightWord: right)
        return HStack(spacing: Space.s6) {
            VStack(alignment: .leading, spacing: 4) {
                T(a.titleKey).susuType(.bodyStrong).foregroundStyle(Palette.ink)
                if recording {
                    HStack(spacing: 6) {
                        T("k.rec").susuType(.body).foregroundStyle(Palette.accentInk)
                        ForEach(capture.liveTokens, id: \.self) { Kbd($0) }
                    }
                } else {
                    HStack(spacing: 6) {
                        ForEach(Array(tokens.enumerated()), id: \.offset) { Kbd($0.element) }
                        if a.keyPath == nil { Kbd(tokens.first ?? "") }
                        T(a.detailKey).susuType(.body).foregroundStyle(Palette.ink2)
                    }
                }
            }
            Spacer(minLength: 0)
            if a.keyPath != nil {
                Button { toggle(a) } label: { recording ? T("cancel") : T("change") }
                    .buttonStyle(.susu(.neutral))
            }
        }
        .padding(.vertical, Space.s4).frame(minHeight: 68)
        .background(recording ? Palette.accentSoft.opacity(0.5) : .clear)
        .settingsRowLine()
    }

    private func toggle(_ a: ShortcutAction) {
        if capture.recordingID == a.id { capture.stop(); return }
        pending = nil
        capture.start(id: a.id) { id, new in apply(id: id, new: new) }
    }

    private func apply(id: String, new: HotkeySetting) {
        guard let a = shortcutActions.first(where: { $0.id == id }), let kp = a.keyPath else { return }
        if let other = shortcutActions.first(where: { $0.id != id && $0.keyPath != nil && ShortcutText.normalized(setting($0)) == new }) {
            pending = (id, new, other.id)
            return
        }
        live.set { $0.hotkeys[keyPath: kp] = new }
    }

    private func conflictRow(_ p: (actionID: String, setting: HotkeySetting, otherID: String)) -> some View {
        let otherTitle = shortcutActions.first { $0.id == p.otherID }?.titleKey ?? ""
        return SNote(text: T("k.conf") + Text(verbatim: " «\(tr(otherTitle, model.language))»"), isError: true) {
            SBtn("k.swap", size: .small) { swap(p) }
            SBtn("cancel", .quiet, size: .small) { pending = nil }
        }
    }

    private func swap(_ p: (actionID: String, setting: HotkeySetting, otherID: String)) {
        guard let a = shortcutActions.first(where: { $0.id == p.actionID })?.keyPath,
              let o = shortcutActions.first(where: { $0.id == p.otherID })?.keyPath else { return }
        let old = live.value.hotkeys[keyPath: a]
        live.set { $0.hotkeys[keyPath: o] = old; $0.hotkeys[keyPath: a] = p.setting }
        pending = nil
    }
}

/// Key cap chip.
struct Kbd: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(verbatim: text).susuType(.caption).foregroundStyle(Palette.ink)
            .padding(.horizontal, 8).frame(height: 24)
            .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.lineStrong, lineWidth: 1))
    }
}

#Preview("Keys, light") {
    let model = ShellModel(services: .temporary())
    return KeysSettingsView().shellRoot(model).frame(width: 700, height: 640).background(Palette.bgCard).preferredColorScheme(.light)
}
