// Main window: sidebar on the warm base, one white content card (inset 8, radius 20).
import SwiftUI
import SusuCore

struct MainWindowView: View {
    @EnvironmentObject private var model: ShellModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            ContentCard {
                SectionRouter.view(for: model.mainSection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .id(model.mainSection)
            }
            .padding(.vertical, Metrics.cardInset)
            .padding(.trailing, Metrics.cardInset)
        }
        .background(Palette.bg)
        .ignoresSafeArea()
        .frame(minWidth: Metrics.mainWindowMinSize.width, minHeight: Metrics.mainWindowMinSize.height)
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var model: ShellModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark()
                Text(verbatim: "Susu").susuType(.title).tracking(-0.2).foregroundStyle(Palette.ink)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, Space.s6)

            VStack(spacing: 2) {
                ForEach(MainSection.allCases) { section in
                    SidebarRow(section.title, symbol: section.symbol, isSelected: model.mainSection == section) {
                        model.mainSection = section
                    }
                    .accessibilityIdentifier("nav.\(section.rawValue)")
                }
            }

            Spacer(minLength: Space.s4)

            VStack(alignment: .leading, spacing: Space.s3) {
                Button { model.openSettings(.account) } label: {
                    Text("shell.cloudHint", bundle: .module)
                        .susuType(.small).foregroundStyle(Palette.ink3)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.plain)
                SidebarRow("nav.settings", symbol: "slider.horizontal.3", isSelected: false) {
                    model.openSettings(nil)
                }
            }
        }
        .padding(.top, 56)
        .padding(.bottom, Space.s4)
        .padding(.horizontal, 12)
        .frame(width: Metrics.sidebarWidth)
    }
}

#Preview("Main window, light") {
    let model = ShellModel(services: .temporary())
    return MainWindowView().shellRoot(model)
        .frame(width: Metrics.mainWindowSize.width, height: Metrics.mainWindowSize.height)
        .preferredColorScheme(.light)
}

#Preview("Main window, dark") {
    let model = ShellModel(services: .temporary())
    return MainWindowView().shellRoot(model)
        .frame(width: Metrics.mainWindowSize.width, height: Metrics.mainWindowSize.height)
        .preferredColorScheme(.dark)
}
