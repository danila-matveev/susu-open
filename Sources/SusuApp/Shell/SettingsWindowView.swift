// Settings window (960×640): nav 260 on the group tone, white body on the right.
import SwiftUI
import SusuCore

struct SettingsWindowView: View {
    @EnvironmentObject private var model: ShellModel

    var body: some View {
        HStack(spacing: 0) {
            SettingsNav()
            SectionRouter.view(for: model.settingsSection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Palette.bgCard)
                .id(model.settingsSection)
        }
        .ignoresSafeArea()
        .frame(width: Metrics.settingsWindowSize.width, height: Metrics.settingsWindowSize.height)
    }
}

private struct SettingsNav: View {
    @EnvironmentObject private var model: ShellModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(SettingsSection.groups.enumerated()), id: \.offset) { index, group in
                Text(group.title, bundle: .module)
                    .susuType(.small).foregroundStyle(Palette.ink3)
                    .padding(.horizontal, 12).padding(.bottom, Space.s2)
                    .padding(.top, index == 0 ? 0 : Space.s5)
                VStack(spacing: 2) {
                    ForEach(group.items) { section in
                        SidebarRow(section.title, symbol: section.symbol, isSelected: model.settingsSection == section) {
                            model.settingsSection = section
                        }
                    .accessibilityIdentifier("nav.\(section.rawValue)")
                    }
                }
            }
            Spacer(minLength: 0)
            Text(verbatim: "Susu \(Susu.version)")
                .susuType(.small).foregroundStyle(Palette.ink3)
                .padding(.horizontal, 12)
        }
        .padding(.top, 52)
        .padding(.bottom, Space.s4)
        .padding(.horizontal, 12)
        .frame(width: Metrics.settingsNavWidth)
        .frame(maxHeight: .infinity)
        .background(Palette.bgGroup)
    }
}

#Preview("Settings, light") {
    let model = ShellModel(services: .temporary())
    return SettingsWindowView().shellRoot(model).preferredColorScheme(.light)
}

#Preview("Settings, dark") {
    let model = ShellModel(services: .temporary())
    return SettingsWindowView().shellRoot(model).preferredColorScheme(.dark)
}
