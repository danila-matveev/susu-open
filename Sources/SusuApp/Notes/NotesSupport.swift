// Small helpers for the Notes screen: strings, dates, highlight, flow layout, player.
import AVFoundation
import SwiftUI
import SusuCore

/// Other parts of the app talk to the Notes screen through this object (the screen has no init arguments).
@MainActor
public final class NotesBridge: ObservableObject {
    public static let shared = NotesBridge()
    /// Ids of notes whose title is still being written by the editor model («Придумываю заголовок…»).
    @Published public var titlePending: Set<String> = []
    /// Set by the app: starts a voice note like holding the right Cmd. nil hides the mic button.
    public var startVoiceNote: (() -> Void)?
    private init() {}
}

enum NS {
    static func string(_ key: String, _ lang: InterfaceLanguage, _ args: CVarArg...) -> String {
        let f = L10n.bundle(for: lang).localizedString(forKey: key, value: nil, table: "Notes")
        return args.isEmpty ? f : String(format: f, locale: L10n.locale(for: lang), arguments: args)
    }
    static func text(_ key: LocalizedStringKey) -> Text { Text(key, tableName: "Notes", bundle: .module) }

    /// «Сегодня · 15:41» (short) or «Сегодня, 15:41» / «12 ноября, 15:41» (full).
    static func date(_ d: Date, short: Bool, _ lang: InterfaceLanguage, now: Date = AppClock.now) -> String {
        let loc = L10n.locale(for: lang)
        var cal = Calendar.current
        cal.locale = loc
        let time = d.formatted(.dateTime.hour().minute().locale(loc))
        let day: String
        if cal.isDate(d, inSameDayAs: now) { day = string("notes.today", lang) }
        else if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { day = string("notes.yesterday", lang) }
        else if short { day = d.formatted(.dateTime.day().month(.abbreviated).locale(loc)) }
        else if cal.component(.year, from: d) == cal.component(.year, from: now) { day = d.formatted(.dateTime.day().month(.wide).locale(loc)) }
        else { day = d.formatted(.dateTime.day().month(.wide).year().locale(loc)) }
        return short ? "\(day) · \(time)" : "\(day), \(time)"
    }

    /// `text` with every word of `query` marked (case-insensitive prefix match is enough for a row).
    static func highlighted(_ text: String, query: String) -> AttributedString {
        var out = AttributedString(text)
        let words = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for w in words {
            var from = out.startIndex
            while from < out.endIndex, let r = out[from...].range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) {
                out[r].backgroundColor = Palette.accentSoft
                from = r.upperBound
            }
        }
        return out
    }
}

/// Wrapping row of views (tags).
struct NotesFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let a = arrange(bounds.width, subviews)
        for (i, p) in a.points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += rowH + lineSpacing; rowH = 0 }
            points.append(CGPoint(x: x, y: y))
            x += sz.width + spacing; rowH = max(rowH, sz.height); maxX = max(maxX, x - spacing)
        }
        return (points, CGSize(width: maxX, height: y + rowH))
    }
}

/// Plays a note's audio file. Speed cycles 1 / 1.5 / 2.
@MainActor
final class NotePlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0   // 0...1
    @Published private(set) var speed: Float = 1
    private(set) var duration: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    init(url: URL?) {
        guard let url, let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.enableRate = true
        p.prepareToPlay()
        player = p
        duration = p.duration
    }

    var current: TimeInterval { (player?.currentTime) ?? 0 }

    func toggle() {
        guard let p = player else { return }
        if isPlaying { p.pause(); isPlaying = false; timer?.invalidate(); return }
        p.rate = speed
        p.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func seek(_ fraction: Double) {
        guard let p = player, duration > 0 else { return }
        p.currentTime = max(0, min(1, fraction)) * duration
        progress = max(0, min(1, fraction))
    }

    func cycleSpeed() {
        speed = speed == 1 ? 1.5 : (speed == 1.5 ? 2 : 1)
        if isPlaying { player?.rate = speed }
    }

    func stop() { player?.stop(); timer?.invalidate(); isPlaying = false }

    private func tick() {
        guard let p = player else { return }
        if !p.isPlaying { isPlaying = false; timer?.invalidate(); if p.currentTime == 0 || p.currentTime >= duration - 0.15 { progress = 0 }; return }
        progress = duration > 0 ? p.currentTime / duration : 0
    }

    static func mmss(_ t: TimeInterval) -> String {
        let s = Int(t.rounded()); return String(format: "%d:%02d", s / 60, s % 60)
    }
}
