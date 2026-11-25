// «Языки»: dictation language, call language and mixed speech, interface language and theme (live).
import SwiftUI
import SusuCore

public struct LanguageSettingsView: View {
    public init() {}
    public var body: some View { LiveHost { live, model in LanguageContent(live: live, model: model) } }
}

private let otherLanguages: [(code: String, key: String)] = [
    ("pt", "l.pt"), ("es", "l.es"), ("en", "l.en2"), ("de", "l.de"), ("fr", "l.fr"), ("it", "l.it"), ("uk", "l.uk"),
]

private struct LanguageContent: View {
    @ObservedObject var live: SettingsLive
    @ObservedObject var model: ShellModel

    var body: some View {
        SettingsPage(section: .lang) {
            SGroup(title: "l.rec", first: true) {
                SRow("l.dict", detail: "l.dict.d") {
                    SSelect(selection: live.binding(\.dictationLanguage), options: [
                        SOption(.auto, key: "l.auto"), SOption(.ru, key: "l.ru"), SOption(.en, key: "l.en"),
                    ], help: tr("l.dict", model.language))
                }
                SRow("l.call") {
                    SSelect(selection: live.binding(\.preferences.callLanguage), options: [
                        SOption(.auto, key: "l.auto"), SOption(.ru, key: "l.ru"), SOption(.other, key: "l.oth"),
                    ], help: tr("l.call", model.language))
                }
                if live.value.preferences.callLanguage == .other {
                    SRow("l.other") {
                        SSelect(selection: live.binding(\.preferences.callOtherLanguage),
                                options: otherLanguages.map { SOption($0.code, key: $0.key) },
                                help: tr("l.other", model.language))
                    }
                }
                SRow("l.mixed", detail: "l.mixed.d") {
                    SSwitch(isOn: live.binding(\.preferences.mixedSpeech), label: tr("l.mixed", model.language))
                }
            }
            SGroup(title: "l.look") {
                SRow("l.ui", detail: "l.ui.d") {
                    SSelect(selection: live.binding(\.interfaceLanguage), options: [
                        SOption(.system, key: "th.sys"), SOption(.ru, verbatim: "Русский"), SOption(.en, verbatim: "English"),
                    ], help: tr("l.ui", model.language))
                }
                SRow("l.theme") {
                    SSelect(selection: live.binding(\.theme), options: [
                        SOption(.system, key: "th.sys"), SOption(.light, key: "th.light"), SOption(.dark, key: "th.dark"),
                    ], help: tr("l.theme", model.language))
                }
            }
        }
    }
}

#Preview("Languages, light") {
    let model = ShellModel(services: .temporary())
    return LanguageSettingsView().shellRoot(model).frame(width: 700, height: 640).background(Palette.bgCard).preferredColorScheme(.light)
}
