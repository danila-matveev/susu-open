// «Созвоны»: ask or start by itself, always/never lists, calendars (placeholder), final pass, echo cancellation.
import SwiftUI
import SusuCore

public struct CallsSettingsView: View {
    public init() {}
    public var body: some View { LiveHost { live, model in CallsContent(live: live, model: model) } }
}

private struct CallsContent: View {
    @ObservedObject var live: SettingsLive
    @ObservedObject var model: ShellModel

    var body: some View {
        SettingsPage(section: .calls) {
            SGroup(title: "c.when", first: true) {
                SRow("c.ask", detail: "c.ask.d") {
                    SSeg(selection: live.binding(\.preferences.callStart), items: [
                        SSegItem(value: .ask, key: "c.ask.a"), SSegItem(value: .auto, key: "c.ask.b"),
                    ])
                }
            }
            SGroup(title: "c.always") {
                AppListEditor(bundleIDs: live.binding(\.preferences.callAlwaysApps), suggestions: SettingsAppCatalog.meetingApps)
            }
            SGroup(title: "c.never") {
                AppListEditor(bundleIDs: live.binding(\.preferences.callNeverApps), suggestions: SettingsAppCatalog.meetingApps)
            }
            SGroup(title: "c.cals") {
                SNote("c.none") {
                    SBtn("c.google", size: .small) {
                        openSystemSettings("x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")
                    }
                }
            }
            SGroup(title: "c.misc") {
                SRow("c.fine", detail: "c.fine.d") {
                    SSwitch(isOn: live.binding(\.preferences.callFinalPass), label: tr("c.fine", model.language))
                }
                SRow("c.echo", detail: "c.echo.d") {
                    SSwitch(isOn: live.binding(\.preferences.callEchoCancellation), label: tr("c.echo", model.language))
                }
            }
        }
    }
}

#Preview("Calls, light") {
    let model = ShellModel(services: .temporary())
    return CallsSettingsView().shellRoot(model).frame(width: 700, height: 700).background(Palette.bgCard).preferredColorScheme(.light)
}
