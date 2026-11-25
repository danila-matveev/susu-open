// «Прочее»: launch at login, Dock icon, sounds, update check.
import AppKit
import SwiftUI
import SusuCore

public struct MiscSettingsView: View {
    public init() {}
    public var body: some View { LiveHost { live, model in MiscContent(live: live, model: model) } }
}

private struct MiscContent: View {
    @ObservedObject var live: SettingsLive
    @ObservedObject var model: ShellModel
    @State private var launchAtLogin = false

    var body: some View {
        SettingsPage(section: .misc) {
            SGroup(title: "x.start", first: true) {
                SRow("x.login", detail: "x.login.d") {
                    SSwitch(isOn: $launchAtLogin, label: tr("x.login", model.language))
                }
                SRow("x.dock", detail: "x.dock.d") {
                    SSwitch(isOn: live.binding(\.preferences.dockIcon), label: tr("x.dock", model.language))
                }
            }
            SGroup(title: "x.sound") {
                SRow("x.sounds", detail: "x.sounds.d") {
                    SSwitch(isOn: live.binding(\.soundsEnabled), label: tr("x.sounds", model.language))
                }
            }
            SGroup(title: "x.upd") {
                SRow("x.auto", detail: "x.auto.d") {
                    SSwitch(isOn: live.binding(\.preferences.checkForUpdates), label: tr("x.auto", model.language))
                }
                SRow(verbatim: "Susu \(Susu.version)", detail: T("x.noupdater")) { EmptyView() }
            }
        }
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
        .onChange(of: launchAtLogin) { _, on in
            guard on != LaunchAtLogin.isEnabled else { return }
            do { try LaunchAtLogin.set(on) } catch { launchAtLogin = LaunchAtLogin.isEnabled }
            live.set { $0.launchAtLogin = launchAtLogin }
        }
        .onChange(of: live.value.preferences.dockIcon) { _, on in
            NSApp.setActivationPolicy(on ? .regular : .accessory)
        }
    }
}

#Preview("Misc, light") {
    let model = ShellModel(services: .temporary())
    return MiscSettingsView().shellRoot(model).frame(width: 700, height: 600).background(Palette.bgCard).preferredColorScheme(.light)
}
