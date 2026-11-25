// Shared pieces of the settings screens: page frame, groups, rows, select, stepper, segmented control.
// Strings live in the «SettingsScreens» table (Resources/SettingsScreens.xcstrings), so these components
// take table keys, not LocalizedStringKey (the Theme components resolve in the main table).
import AppKit
import SwiftUI
import SusuCore

let settingsTable = "SettingsScreens"

/// Text from the settings string table; follows `\.locale` like every SwiftUI Text.
func T(_ key: String) -> Text {
    Text(LocalizedStringKey(key), tableName: settingsTable, bundle: .module)
}

/// String from the settings table for AppKit/String uses (placeholders, panels, accessibility).
func tr(_ key: String, _ language: InterfaceLanguage) -> String {
    L10n.bundle(for: language).localizedString(forKey: key, value: nil, table: settingsTable)
}

// MARK: - Live settings

/// Observable mirror of `SettingsStore` for the settings screens: reads the current value, writes through `set`.
@MainActor
final class SettingsLive: ObservableObject {
    @Published private(set) var value: SusuCore.Settings
    let store: SettingsStore
    private var task: Task<Void, Never>?

    private static var cache: [ObjectIdentifier: SettingsLive] = [:]
    static func shared(for store: SettingsStore) -> SettingsLive {
        if let live = cache[ObjectIdentifier(store)] { return live }
        let live = SettingsLive(store: store)
        cache[ObjectIdentifier(store)] = live
        return live
    }

    private init(store: SettingsStore) {
        self.store = store
        value = store.current
        task = Task { [weak self] in
            for await s in store.changes() {
                guard let self else { return }
                if self.value != s { self.value = s }
            }
        }
    }

    deinit { task?.cancel() }

    func set(_ change: @escaping (inout SusuCore.Settings) -> Void) {
        _ = try? store.update(change)
    }

    func binding<V>(_ keyPath: WritableKeyPath<SusuCore.Settings, V>) -> Binding<V> {
        Binding(get: { self.value[keyPath: keyPath] },
                set: { new in self.set { $0[keyPath: keyPath] = new } })
    }
}

/// Gives a screen the live settings and the shell model from the environment.
struct LiveHost<Content: View>: View {
    @EnvironmentObject private var model: ShellModel
    let content: (SettingsLive, ShellModel) -> Content
    var body: some View { content(SettingsLive.shared(for: model.store), model) }
}

// MARK: - Page, groups, rows

/// Title, optional lead sentence, scrolling content. `section.title` is the main-table key of the window nav.
struct SettingsPage<Content: View>: View {
    let section: SettingsSection
    var lead: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(section.title)
                if let lead {
                    T(lead).susuType(.body).foregroundStyle(Palette.ink2)
                        .frame(maxWidth: 560, alignment: .leading)
                        .padding(.horizontal, 36).padding(.top, 10)
                }
                content
                Color.clear.frame(height: 36)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A titled block of rows on the group tone. `first` uses the tighter gap under the page header.
struct SGroup<Content: View>: View {
    var title: String?
    var first = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                T(title).susuType(.title2).foregroundStyle(Palette.ink)
                    .padding(.top, first ? 24 : 32).padding(.bottom, 12)
            }
            GroupedRows { content }
                .padding(.top, title == nil ? (first ? 24 : 12) : 0)
        }
        .padding(.horizontal, 36)
    }
}

/// Hairline above a row inside `GroupedRows`.
private struct RowLine: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

extension View {
    func settingsRowLine() -> some View { modifier(RowLine()) }
}

/// Label + description left, control right.
struct SRow<Control: View>: View {
    let title: Text
    var detail: Text?
    @ViewBuilder var control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = T(title); self.detail = detail.map { T($0) }; self.control = control()
    }
    init(verbatim title: String, detail: Text? = nil, @ViewBuilder control: () -> Control) {
        self.title = Text(verbatim: title); self.detail = detail; self.control = control()
    }

    var body: some View {
        HStack(spacing: Space.s6) {
            VStack(alignment: .leading, spacing: 2) {
                title.susuType(.bodyStrong).foregroundStyle(Palette.ink)
                if let detail { detail.susuType(.body).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
            control
        }
        .padding(.vertical, Space.s4)
        .frame(minHeight: 68)
        .settingsRowLine()
    }
}

/// Plain sentence row with optional buttons on the right.
struct SNote<Actions: View>: View {
    let text: Text
    var isError = false
    @ViewBuilder var actions: Actions

    init(_ key: String, isError: Bool = false, @ViewBuilder actions: () -> Actions) {
        text = T(key); self.isError = isError; self.actions = actions()
    }
    init(text: Text, isError: Bool = false, @ViewBuilder actions: () -> Actions) {
        self.text = text; self.isError = isError; self.actions = actions()
    }

    var body: some View {
        HStack(spacing: Space.s4) {
            text.susuType(.body).foregroundStyle(isError ? Palette.error : Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 8) { actions }
        }
        .padding(.vertical, 14)
        .settingsRowLine()
    }
}

extension SNote where Actions == EmptyView {
    init(_ key: String, isError: Bool = false) { self.init(key, isError: isError) { EmptyView() } }
}

/// Free-form row (lists, fields) with the hairline and tight padding.
struct SFree<Content: View>: View {
    var padding: CGFloat = 10
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(.vertical, padding).frame(maxWidth: .infinity, alignment: .leading).settingsRowLine()
    }
}

// MARK: - Controls

@MainActor
func SBtn(_ key: String, _ kind: SusuButtonKind = .neutral, size: SusuControlSize = .regular,
          action: @escaping () -> Void) -> some View {
    Button(action: action) { T(key) }.buttonStyle(.susu(kind, size: size))
}

struct SOption<V: Hashable>: Identifiable {
    let value: V
    let label: Text
    var id: V { value }
    init(_ value: V, key: String) { self.value = value; label = T(key) }
    init(_ value: V, verbatim: String) { self.value = value; label = Text(verbatim: verbatim) }
}

/// Dropdown in the prototype's `.sel` look: card fill, strong hairline, chevron.
struct SSelect<V: Hashable>: View {
    @Binding var selection: V
    let options: [SOption<V>]
    var width: CGFloat? = 180
    var help: String = ""
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(options) { o in
                Button { selection = o.value } label: {
                    if o.value == selection { Label { o.label } icon: { Image(systemName: "checkmark") } } else { o.label }
                }
            }
        } label: {
            HStack(spacing: 8) {
                (options.first { $0.value == selection }?.label ?? Text(verbatim: "—"))
                    .susuType(.label).foregroundStyle(Palette.ink).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.ink2)
            }
            .padding(.horizontal, 12)
            .frame(width: width, height: Metrics.control)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(hovering ? Palette.ink3 : Palette.lineStrong, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(help))
    }
}

/// Text input in the prototype's `.input` look.
struct SField: View {
    @Binding var text: String
    var placeholder: String = ""
    var secure = false
    var mono = false
    var disabled = false
    var onCommit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if secure {
                SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(Palette.ink3))
            } else {
                TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Palette.ink3))
            }
        }
        .textFieldStyle(.plain).susuType(.body).foregroundStyle(Palette.ink)
        .font(mono ? .system(size: 14, design: .monospaced) : nil)
        .autocorrectionDisabled()
        .focused($focused)
        .onSubmit(onCommit)
        .onChange(of: focused) { _, now in if !now { onCommit() } }
        .padding(.horizontal, 12).frame(height: Metrics.control)
        .background(disabled ? Palette.bgGroup : Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .strokeBorder(focused ? Palette.accent : Palette.lineStrong, lineWidth: 1))
        .opacity(disabled ? 0.45 : 1)
        .disabled(disabled)
    }
}

/// − value + control for seconds.
struct SStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let locale: Locale
    let unit: String

    var body: some View {
        HStack(spacing: 0) {
            button("minus", enabled: value - step >= range.lowerBound - 0.0001) { value = clamp(value - step) }
            Text("\(value.formatted(.number.precision(.fractionLength(0...2)).locale(locale))) \(unit)")
                .susuType(.label).monospacedDigit().foregroundStyle(Palette.ink)
                .frame(minWidth: 64)
            button("plus", enabled: value + step <= range.upperBound + 0.0001) { value = clamp(value + step) }
        }
        .frame(height: Metrics.control)
        .background(Palette.bgFill, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }

    private func clamp(_ v: Double) -> Double { (min(max(v, range.lowerBound), range.upperBound) * 100).rounded() / 100 }

    private func button(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink2)
                .frame(width: 36, height: Metrics.control).contentShape(Rectangle())
        }
        .buttonStyle(.plain).opacity(enabled ? 1 : 0.4).disabled(!enabled)
    }
}

struct SSegItem<V: Hashable>: Identifiable {
    let value: V
    let key: String
    var symbol: String?
    var disabled = false
    var id: V { value }
}

/// Segmented pill control (`.seg`); `large` is the full-width tab strip with icons (`.tabs`).
struct SSeg<V: Hashable>: View {
    @Binding var selection: V
    let items: [SSegItem<V>]
    var large = false
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let on = item.value == selection
                Button { selection = item.value } label: {
                    HStack(spacing: 8) {
                        if let s = item.symbol { Image(systemName: s).font(.system(size: 13)) }
                        T(item.key)
                    }
                    .susuType(large ? .label : .small).fontWeight(.medium)
                    .foregroundStyle(on ? Palette.ink : Palette.ink2)
                    .padding(.horizontal, large ? 16 : 12)
                    .frame(maxWidth: large ? .infinity : nil)
                    .frame(height: large ? 36 : 28)
                    .background {
                        if on { Capsule().fill(Palette.bgCard).susuShadow(.card, radius: 18).matchedGeometryEffect(id: "pill", in: ns) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(item.disabled).opacity(item.disabled ? 0.4 : 1)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(large ? 4 : 3)
        .background(Palette.bgFill, in: Capsule())
        .susuAnimation(Motion.standard, value: selection)
    }
}

struct SSwitch: View {
    @Binding var isOn: Bool
    var label: String = ""
    var body: some View {
        Toggle(isOn: $isOn) { EmptyView() }.toggleStyle(.susu).labelsHidden().accessibilityLabel(Text(label))
    }
}

/// Dot + caption (the prototype's `.badge`).
struct SBadge: View {
    enum Kind { case neutral, ok, error, busy }
    let text: Text
    var kind = Kind.neutral
    var body: some View {
        HStack(spacing: 6) {
            if kind == .busy {
                ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 10, height: 10)
            } else {
                Circle().fill(tint).frame(width: 6, height: 6)
            }
            text.susuType(.caption).foregroundStyle(kind == .ok ? Palette.ok : kind == .error ? Palette.error : Palette.ink2)
        }
        .fixedSize()
    }
    private var tint: Color { kind == .ok ? Palette.ok : kind == .error ? Palette.error : Palette.ink3 }
}

/// Meter bar (`.meter`): track on the fill tone, accent bar.
struct SMeter: View {
    var value: Double  // 0...1
    var tint: Color = Palette.accent
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.bgFill)
                Capsule().fill(tint).frame(width: max(height, geo.size.width * min(max(value, 0), 1)))
                    .opacity(value <= 0 ? 0 : 1)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Apps

/// Names and icons of apps by bundle ID (call lists, exclusions).
enum SettingsAppCatalog {
    static let knownNames: [String: String] = [
        "com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password 7",
        "com.agilebits.onepassword-osx": "1Password", "com.bitwarden.desktop": "Bitwarden",
        "com.apple.keychainaccess": "Keychain Access", "org.keepassxc.keepassxc": "KeePassXC",
        "com.lastpass.lastpassmacdesktop": "LastPass", "com.apple.Passwords": "Passwords",
        "com.nubank.mobile": "Nubank", "br.com.itau.itauapp": "Itaú", "com.tinkoff.TinkoffBank": "Tinkoff",
        "ru.sberbankruapp": "Sber Online",
        "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Microsoft Teams", "com.tinyspeck.slackmacgap": "Slack",
        "com.apple.FaceTime": "FaceTime", "com.hnc.Discord": "Discord", "ru.keepcoder.Telegram": "Telegram",
        "Cisco-Systems.Spark": "Webex", "com.readdle.smartemail-Mac": "Spark",
    ]

    /// Apps offered in «Always record» lists.
    static let meetingApps = ["us.zoom.xos", "com.microsoft.teams2", "com.tinyspeck.slackmacgap",
                              "com.apple.FaceTime", "com.hnc.Discord", "ru.keepcoder.Telegram", "Cisco-Systems.Spark"]
    static let sensitiveApps = ["com.1password.1password", "com.bitwarden.desktop", "com.apple.keychainaccess",
                                "org.keepassxc.keepassxc", "com.apple.Passwords", "com.nubank.mobile"]

    static func url(for bundleID: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    static func name(for bundleID: String) -> String {
        if let url = url(for: bundleID) { return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }
        return knownNames[bundleID] ?? bundleID
    }

    static func icon(for bundleID: String) -> NSImage? {
        url(for: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Visible running apps except Susu itself.
    static func runningApps() -> [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Lets the user pick an .app from disk; returns its bundle ID.
    @MainActor static func pickFromDisk() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}

struct SettingsAppIcon: View {
    let bundleID: String
    var body: some View {
        Group {
            if let icon = SettingsAppCatalog.icon(for: bundleID) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Text(String(SettingsAppCatalog.name(for: bundleID).prefix(1)).uppercased())
                    .susuType(.small).fontWeight(.semibold).foregroundStyle(Palette.ink2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.bgFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .frame(width: 28, height: 28)
    }
}

/// Editable list of apps by bundle ID: rows with remove buttons, «Add app…» menu at the bottom.
struct AppListEditor: View {
    @Binding var bundleIDs: [String]
    let suggestions: [String]
    @State private var running: [(id: String, name: String)] = []

    var body: some View {
        Group {
            if bundleIDs.isEmpty {
                SFree(padding: 14) { T("apps.empty").susuType(.body).foregroundStyle(Palette.ink3) }
            } else {
                ForEach(bundleIDs, id: \.self) { id in
                    SFree {
                        HStack(spacing: 12) {
                            SettingsAppIcon(bundleID: id)
                            Text(verbatim: SettingsAppCatalog.name(for: id)).susuType(.body).fontWeight(.medium).foregroundStyle(Palette.ink)
                            Spacer(minLength: 0)
                            IconButton("minus.circle", help: nil) { bundleIDs.removeAll { $0 == id } }
                        }
                    }
                }
            }
            SFree {
                Menu {
                    let offered = suggestions.filter { !bundleIDs.contains($0) }
                    ForEach(offered, id: \.self) { id in
                        Button(SettingsAppCatalog.name(for: id)) { bundleIDs.append(id) }
                    }
                    let extra = running.filter { !bundleIDs.contains($0.id) && !suggestions.contains($0.id) }
                    if !extra.isEmpty {
                        Divider()
                        ForEach(extra, id: \.id) { app in Button(app.name) { bundleIDs.append(app.id) } }
                    }
                    Divider()
                    Button { if let id = SettingsAppCatalog.pickFromDisk(), !bundleIDs.contains(id) { bundleIDs.append(id) } } label: { T("apps.pick") }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                        T("apps.add")
                    }
                    .susuType(.label).foregroundStyle(Palette.accentInk)
                    .padding(.horizontal, 12).frame(height: Metrics.controlSmall)
                    .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .onAppear { running = SettingsAppCatalog.runningApps() }
            }
        }
    }
}

/// Opens a System Settings pane.
func openSystemSettings(_ url: String) {
    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
}
