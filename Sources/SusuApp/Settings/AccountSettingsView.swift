// «Аккаунт»: Susu Cloud sign-in is not built yet (honest note), work mode picker.
import SwiftUI
import SusuCore

public struct AccountSettingsView: View {
    public init() {}
    public var body: some View { LiveHost { live, model in AccountContent(live: live, model: model) } }
}

private struct AccountContent: View {
    @ObservedObject var live: SettingsLive
    @ObservedObject var model: ShellModel

    private var mode: WorkMode { live.value.preferences.workMode }

    var body: some View {
        SettingsPage(section: .account) {
            VStack(alignment: .leading, spacing: 0) {
                T("ac.mode").susuType(.title2).foregroundStyle(Palette.ink).padding(.top, 24).padding(.bottom, 12)
                SSeg(selection: live.binding(\.preferences.workMode), items: [
                    SSegItem(value: .cloud, key: "mc.cloud", symbol: "cloud", disabled: true),
                    SSegItem(value: .ownKeys, key: "mc.keys", symbol: "key"),
                    SSegItem(value: .macOnly, key: "mc.mac", symbol: "laptopcomputer"),
                ], large: true)
                (T(mode == .cloud ? "mc.cloud.d" : mode == .ownKeys ? "mc.keys.d" : "mc.mac.d") + Text(verbatim: " ") + T("mc.next"))
                    .susuType(.body).foregroundStyle(Palette.ink2).padding(.top, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 36)
            SGroup(title: "ac.sign") {
                SRow("si.t", detail: "si.soon") {
                    Button { } label: { T("si.btn") }.buttonStyle(.susu(.primary)).disabled(true)
                }
                SNote("si.noacc")
            }
        }
    }
}

#Preview("Account, light") {
    let model = ShellModel(services: .temporary())
    return AccountSettingsView().shellRoot(model).frame(width: 700, height: 520).background(Palette.bgCard).preferredColorScheme(.light)
}
