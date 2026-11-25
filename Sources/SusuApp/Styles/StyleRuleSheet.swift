// «Где применять»: sheet that adds one condition (app, address pattern or window title).
import SwiftUI
import SusuCore

struct RuleSheet: View {
    @EnvironmentObject private var shell: ShellModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: StylesModel
    let style: Style

    private enum Kind: Hashable { case app, url, title }

    @State private var kind: Kind = .app
    @State private var selectedApp: String?
    @State private var text = ""
    @State private var running: [AppInfo] = []
    @State private var recent: [AppInfo] = []

    private var s: TableStrings { shell.strings("Styles") }
    private var canAdd: Bool {
        kind == .app ? selectedApp != nil : !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(s.format("st.sheet.title", vm.displayName(style, s))).susuType(.title).tracking(-0.2).foregroundStyle(Palette.ink)
            PillTabs(selection: $kind, items: [(.app, s("st.sheet.app")), (.url, s("st.sheet.url")), (.title, s("st.sheet.window"))],
                     fill: true)
            Group {
                switch kind {
                case .app: appPicker
                case .url:
                    Field(s("st.sheet.urlLabel"), hint: s("st.sheet.urlHint")) {
                        LineField(text: $text, placeholder: "*.bitrix24.ru/*", mono: true)
                    }
                case .title:
                    Field(s("st.sheet.windowLabel"), hint: s("st.sheet.windowHint")) {
                        LineField(text: $text, placeholder: "Lumera")
                    }
                }
            }
            Text(s("st.sheet.prio")).susuType(.small).foregroundStyle(Palette.ink2)
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("Esc").susuType(.caption).padding(.horizontal, 6).frame(height: 20)
                        .background(Palette.bgFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(s("st.sheet.esc"))
                }
                .susuType(.small).foregroundStyle(Palette.ink3)
                Spacer()
                Button(s("st.sheet.cancel")) { dismiss() }.buttonStyle(.susu(.neutral)).keyboardShortcut(.cancelAction)
                Button(s("st.sheet.add"), action: add).buttonStyle(.susu(.primary)).disabled(!canAdd)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
        .background(Palette.bgCard)
        .onChange(of: kind) { _, _ in text = ""; selectedApp = nil }
        .task { await loadApps() }
    }

    // MARK: App picker

    private var appPicker: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                if running.isEmpty && recent.isEmpty {
                    Text(s("st.sheet.noApps")).susuType(.small).foregroundStyle(Palette.ink3).gridCellColumns(2)
                }
                if !running.isEmpty { sectionHeader(s("st.sheet.running")); ForEach(running) { appCell($0) } }
                if !recent.isEmpty { sectionHeader(s("st.sheet.recent")); ForEach(recent) { appCell($0) } }
            }
        }
        .scrollIndicators(.never)
        .frame(height: 300)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).susuType(.caption).foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4).padding(.top, 6)
            .gridCellColumns(2)
    }

    private func owner(of bundleId: String) -> Style? {
        guard let rule = vm.rules.first(where: { $0.kind == "bundle" && $0.pattern == bundleId }) else { return nil }
        return vm.styles.first { $0.id == rule.styleId }
    }

    private func appCell(_ app: AppInfo) -> some View {
        let owner = owner(of: app.bundleId)
        let here = owner?.id == style.id
        let chosen = selectedApp == app.bundleId
        let note = here ? s("st.sheet.here")
            : owner.map { s.format("st.sheet.other", vm.displayName($0, s)) } ?? s("st.sheet.free")
        return Button { selectedApp = app.bundleId } label: {
            HStack(spacing: 10) {
                AppIconView(bundleId: app.bundleId, fallbackName: app.name, size: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.name).susuType(.label).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(note).susuType(.caption).foregroundStyle(Palette.ink3).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accentInk)
                    .opacity(chosen ? 1 : 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(chosen ? Palette.accentSoft : Palette.bgGroup, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .opacity(here ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(here)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func loadApps() async {
        let live = AppCatalog.running()
        running = live
        let liveIds = Set(live.map(\.bundleId))
        let used = (try? await StatsQueries(database: shell.services.database).recentApps(limit: 30)) ?? []
        recent = used.filter { !liveIds.contains($0.bundleId) }.map {
            AppInfo(bundleId: $0.bundleId, name: AppCatalog.installedName($0.bundleId) ?? $0.appName ?? $0.bundleId)
        }
    }

    private func add() {
        let value = text.trimmingCharacters(in: .whitespaces)
        let styleId = style.id
        switch kind {
        case .app: if let id = selectedApp { Task { await vm.addRule(styleId: styleId, kind: "bundle", pattern: id) } }
        case .url: Task { await vm.addRule(styleId: styleId, kind: "url", pattern: value) }
        case .title: Task { await vm.addRule(styleId: styleId, kind: "title", pattern: value) }
        }
        dismiss()
    }
}
