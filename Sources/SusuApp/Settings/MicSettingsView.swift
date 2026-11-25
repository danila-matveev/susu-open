// «Микрофон»: priority list (drag to reorder), live level meter while the screen is open, two options.
import AVFoundation
import SwiftUI
import SusuCore

/// Runs a MicRecorder only to draw a level bar; the recording is thrown away.
@MainActor
final class MicLevelTest: ObservableObject {
    enum State { case idle, listening, failed }
    @Published private(set) var level: Double = 0
    @Published private(set) var state = State.idle
    @Published private(set) var silent = false
    private var recorder: MicRecorder?
    private var lastSound = Date()

    func start(priority: [String]) {
        stop()
        let r = MicRecorder(devicePriority: priority)
        lastSound = Date(); silent = false
        do {
            try r.start(onLevel: { [weak self] l in
                Task { @MainActor in self?.receive(Double(l)) }
            })
            recorder = r
            state = .listening
        } catch {
            state = .failed
        }
    }

    func stop() {
        if let r = recorder {
            let rec = r.stop()
            if let url = rec.wavURL { try? FileManager.default.removeItem(at: url) }
        }
        recorder = nil
        if state == .listening { state = .idle }
        level = 0; silent = false
    }

    private func receive(_ l: Double) {
        guard state == .listening else { return }
        level = level * 0.4 + l * 0.6
        if l > 0.05 { lastSound = Date(); silent = false }
        else if Date().timeIntervalSince(lastSound) > 4 { silent = true }
    }
}

public struct MicSettingsView: View {
    public init() {}
    public var body: some View { LiveHost { live, model in MicContent(live: live, model: model) } }
}

private struct MicEntry: Identifiable, Equatable {
    var id: String       // uid or saved name
    var name: String
    var present: Bool
}

private struct MicContent: View {
    @ObservedObject var live: SettingsLive
    @ObservedObject var model: ShellModel
    @StateObject private var test = MicLevelTest()
    @State private var devices: [(uid: String, name: String)] = []
    @State private var auth = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var dragging: String?

    private var entries: [MicEntry] {
        var out: [MicEntry] = []
        for p in live.value.micPriority {
            if let d = devices.first(where: { $0.uid == p || $0.name.lowercased().contains(p.lowercased()) }) {
                if !out.contains(where: { $0.id == d.uid }) { out.append(MicEntry(id: d.uid, name: d.name, present: true)) }
            } else {
                out.append(MicEntry(id: p, name: p, present: false))
            }
        }
        for d in devices where !out.contains(where: { $0.id == d.uid }) { out.append(MicEntry(id: d.uid, name: d.name, present: true)) }
        return out
    }

    var body: some View {
        SettingsPage(section: .mic, lead: "m.lead") {
            SGroup(title: "m.list", first: true) {
                let list = entries
                if list.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "mic").font(.system(size: 32, weight: .light)).foregroundStyle(Palette.ink3)
                        T("m.none").susuType(.bodyStrong).foregroundStyle(Palette.ink)
                        T("m.none.d").susuType(.body).foregroundStyle(Palette.ink2).multilineTextAlignment(.center)
                        SBtn("m.sys") { openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 28).settingsRowLine()
                } else {
                    let firstPresent = list.first { $0.present }?.id
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                        micRow(e, index: i, current: e.id == firstPresent, all: list)
                    }
                }
            }
            SGroup(title: "m.test") { testRow }
            SGroup(title: "m.opts") {
                SRow("m.lid", detail: "m.lid.d") {
                    SSwitch(isOn: live.binding(\.preferences.micSkipBuiltInWhenLidClosed), label: tr("m.lid", model.language))
                }
                SRow("m.head", detail: "m.head.d") {
                    SSwitch(isOn: live.binding(\.preferences.micPreferMacOnHeadphones), label: tr("m.head", model.language))
                }
            }
        }
        .task {
            while !Task.isCancelled {
                let now = MicRecorder.availableInputDevices()
                if now.map(\.uid) != devices.map(\.uid) { devices = now }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .onAppear {
            auth = AVCaptureDevice.authorizationStatus(for: .audio)
            if auth == .authorized { test.start(priority: live.value.micPriority) }
        }
        .onDisappear { test.stop() }
        .onChange(of: live.value.micPriority) { _, p in if test.state == .listening { test.start(priority: p) } }
    }

    private var testRow: some View {
        SFree(padding: 16) {
            HStack(spacing: Space.s4) {
                VStack(alignment: .leading, spacing: 8) {
                    SMeter(value: test.level, height: 10)
                    if auth == .denied || auth == .restricted {
                        T("m.denied").susuType(.body).foregroundStyle(Palette.error)
                    } else if test.state == .failed {
                        T("m.failed").susuType(.body).foregroundStyle(Palette.error)
                    } else if test.silent {
                        T("m.silent").susuType(.body).foregroundStyle(Palette.error)
                    } else if test.state == .listening {
                        T("m.listening").susuType(.body).foregroundStyle(Palette.ink2)
                    } else {
                        T("m.idle").susuType(.body).foregroundStyle(Palette.ink2)
                    }
                }
                if auth == .denied || auth == .restricted {
                    SBtn("m.sys") { openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }
                } else if test.state == .listening {
                    SBtn("m.stop") { test.stop() }
                } else {
                    SBtn("m.test.b") {
                        test.start(priority: live.value.micPriority)
                        auth = AVCaptureDevice.authorizationStatus(for: .audio)
                    }
                }
            }
        }
    }

    private func micRow(_ e: MicEntry, index: Int, current: Bool, all: [MicEntry]) -> some View {
        SFree {
            HStack(spacing: 12) {
                Image(systemName: "line.3.horizontal").font(.system(size: 14)).foregroundStyle(Palette.ink3).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: e.name).susuType(.body).fontWeight(.medium).foregroundStyle(e.present ? Palette.ink : Palette.ink3)
                    if !e.present { T("m.absent").susuType(.small).foregroundStyle(Palette.ink3) }
                }
                Spacer(minLength: 0)
                if current { SBadge(text: T("m.now"), kind: .ok) }
                else { Text(verbatim: "\(index + 1)").susuType(.small).monospacedDigit().foregroundStyle(Palette.ink3) }
                HStack(spacing: 0) {
                    IconButton("chevron.up") { move(e.id, by: -1, in: all) }.opacity(index == 0 ? 0.3 : 1).disabled(index == 0)
                    IconButton("chevron.down") { move(e.id, by: 1, in: all) }.opacity(index == all.count - 1 ? 0.3 : 1).disabled(index == all.count - 1)
                }
            }
            .contentShape(Rectangle())
            .draggable(e.id) { Text(verbatim: e.name).padding(8).background(Palette.bgCard) }
            .dropDestination(for: String.self) { items, _ in
                guard let from = items.first, let fromIdx = all.firstIndex(where: { $0.id == from }) else { return false }
                reorder(all, from: fromIdx, to: index)
                return true
            }
        }
    }

    private func move(_ id: String, by delta: Int, in all: [MicEntry]) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        reorder(all, from: i, to: i + delta)
    }

    private func reorder(_ all: [MicEntry], from: Int, to: Int) {
        guard from != to, all.indices.contains(to) else { return }
        var ids = all.map(\.id)
        let moved = ids.remove(at: from)
        ids.insert(moved, at: to)
        live.set { $0.micPriority = ids }
    }
}

#Preview("Mic, light") {
    let model = ShellModel(services: .temporary())
    return MicSettingsView().shellRoot(model).frame(width: 700, height: 640).background(Palette.bgCard).preferredColorScheme(.light)
}
