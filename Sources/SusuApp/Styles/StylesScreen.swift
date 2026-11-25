// «Стили»: list of styles on the left, editor on the right. Edits apply at once (debounced save).
import SwiftUI
import SusuCore

@MainActor
final class StylesModel: ObservableObject {
    @Published private(set) var styles: [Style] = []
    @Published private(set) var rules: [StyleRule] = []
    @Published var selectedId: String?
    /// Bumped after every save, the editor flashes «Сохранено» on change.
    @Published private(set) var savedTick = 0

    let services: AppServices
    private var pending: [String: Task<Void, Never>] = [:]

    init(services: AppServices) { self.services = services }

    var selected: Style? { styles.first { $0.id == selectedId } }
    var defaultStyle: Style? { styles.first { $0.isDefault } }
    func rules(of styleId: String) -> [StyleRule] { rules.filter { $0.styleId == styleId } }

    func load() async {
        try? await services.styles.seedDefaultsIfEmpty()
        await reload()
        if selected == nil { selectedId = styles.first?.id }
    }

    private func reload() async {
        styles = (try? await services.styles.styles()) ?? styles
        rules = (try? await services.styles.rules()) ?? rules
        if let id = selectedId, !styles.contains(where: { $0.id == id }) { selectedId = styles.first?.id }
    }

    /// Updates the list at once and saves after a short pause (typing in the name or rule field).
    func edit(_ style: Style) {
        guard let i = styles.firstIndex(where: { $0.id == style.id }), styles[i] != style else { return }
        styles[i] = style
        pending[style.id]?.cancel()
        pending[style.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.persist(style.id)
        }
    }

    private func persist(_ id: String) async {
        pending[id] = nil
        guard var style = styles.first(where: { $0.id == id }) else { return }
        style.updatedAt = Date()
        try? await services.styles.save(style: style)
        savedTick += 1
    }

    /// Saves everything still waiting (the window or the style is going away).
    func flush() async {
        let ids = Array(pending.keys)
        for id in ids { pending[id]?.cancel(); await persist(id) }
    }

    func makeDefault(_ id: String) async {
        await flush()
        guard var style = styles.first(where: { $0.id == id }) else { return }
        style.isDefault = true; style.updatedAt = Date()
        try? await services.styles.save(style: style)
        await reload()
        savedTick += 1
    }

    /// New style goes before the default one, like in the prototype.
    func addStyle(name: String) async {
        await flush()
        let fresh = Style(name: name, cleanupLevel: CleanupLevel.normal.rawValue)
        let ordered = styles.filter { !$0.isDefault } + [fresh] + styles.filter(\.isDefault)
        for (i, var s) in ordered.enumerated() {
            let sort = i + 1
            if s.sort != sort || s.id == fresh.id { s.sort = sort; s.updatedAt = Date(); try? await services.styles.save(style: s) }
        }
        await reload()
        selectedId = fresh.id
    }

    func delete(_ id: String) async {
        await flush()
        let index = styles.firstIndex { $0.id == id } ?? 0
        try? await services.styles.delete(styleId: id)
        await reload()
        selectedId = styles.indices.contains(index - 1) ? styles[index - 1].id : styles.first?.id
    }

    /// An app belongs to one style: adding it here removes it from the style that had it.
    func addRule(styleId: String, kind: String, pattern: String) async {
        if kind == "bundle" {
            for r in rules where r.kind == "bundle" && r.pattern == pattern && r.styleId != styleId {
                try? await services.styles.delete(ruleId: r.id)
            }
        }
        try? await services.styles.save(rule: StyleRule(styleId: styleId, kind: kind, pattern: pattern))
        await reload()
        savedTick += 1
    }

    func removeRule(_ id: String) async {
        try? await services.styles.delete(ruleId: id)
        await reload()
        savedTick += 1
    }

    /// Default styles keep the Russian names they were seeded with; show them in the interface language.
    func displayName(_ style: Style, _ s: TableStrings) -> String {
        let seeded: [String: (ru: String, key: String)] = [
            "style-code": ("Код", "code"), "style-messengers": ("Мессенджеры", "messengers"), "style-mail": ("Почта", "mail"),
            "style-tasks": ("Задачи и заметки", "tasks"), "style-other": ("Прочее", "other"),
        ]
        if let d = seeded[style.id], d.ru == style.name { return s("st.name.\(d.key)") }
        return style.name
    }
}

public struct StylesScreen: View {
    @EnvironmentObject private var shell: ShellModel
    public init() {}
    public var body: some View { StylesBody(services: shell.services) }
}

private struct StylesBody: View {
    @EnvironmentObject private var shell: ShellModel
    @StateObject private var vm: StylesModel

    init(services: AppServices) { _vm = StateObject(wrappedValue: StylesModel(services: services)) }

    private var s: TableStrings { shell.strings("Styles") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHead(title: s("st.title"), subtitle: s("st.subtitle")) {
                Button {
                    Task { await vm.addStyle(name: s("st.newName")) }
                } label: {
                    HStack(spacing: 8) { Image(systemName: "plus").font(.system(size: 13, weight: .semibold)); Text(s("st.new")) }
                }
                .buttonStyle(.susu(.primary))
                .padding(.top, 2)
            }

            if vm.styles.isEmpty {
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    StyleList(vm: vm).frame(width: 252)
                    if let style = vm.selected {
                        StyleEditor(vm: vm, style: style).id(style.id)
                    }
                }
                .padding(.horizontal, 28).padding(.top, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await vm.load() }
        .onDisappear { Task { await vm.flush() } }
    }
}

private struct StyleList: View {
    @EnvironmentObject private var shell: ShellModel
    @ObservedObject var vm: StylesModel
    private var s: TableStrings { shell.strings("Styles") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text(s("st.listCaption")).susuType(.small).foregroundStyle(Palette.ink3)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                ForEach(vm.styles) { style in
                    StyleListRow(title: vm.displayName(style, s), caption: caption(style), isDefault: style.isDefault,
                                 selected: style.id == vm.selectedId, defaultTag: s("st.default.tag")) {
                        Task { await vm.flush() }
                        vm.selectedId = style.id
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.never)
    }

    private func caption(_ style: Style) -> String {
        let n = vm.rules(of: style.id).count
        let where_ = n > 0 ? "\(n) \(s.plural(n, "st.cond"))" : (style.isDefault ? s("st.caption.rest") : s("st.caption.nowhere"))
        return "\(s("st.level.\(style.level.rawValue)")) · \(where_)"
    }
}

private struct StyleListRow: View {
    let title: String
    let caption: String
    let isDefault: Bool
    let selected: Bool
    let defaultTag: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).susuType(.label).fontWeight(selected ? .semibold : .medium).foregroundStyle(Palette.ink).lineLimit(1)
                    if isDefault {
                        Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Palette.ink3)
                            .help(defaultTag)
                    }
                }
                Text(caption).susuType(.small).foregroundStyle(Palette.ink3).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Palette.bgGroup : (hovering ? Palette.bgHover : .clear),
                        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .susuAnimation(Motion.fast, value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Previews

@MainActor
private func previewShell(language: InterfaceLanguage = .ru) -> ShellModel {
    let services = AppServices.temporary()
    _ = try? services.settings.update { $0.interfaceLanguage = language }
    return ShellModel(services: services)
}

#Preview("Styles, light") {
    StylesScreen().shellRoot(previewShell())
        .frame(width: 950, height: 780).background(Palette.bgCard).preferredColorScheme(.light)
}

#Preview("Styles, dark") {
    StylesScreen().shellRoot(previewShell())
        .frame(width: 950, height: 780).background(Palette.bgCard).preferredColorScheme(.dark)
}
