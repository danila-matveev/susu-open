// «Статистика»: words, speed, streak calendar, dictations by app, latency, spend (prototype window-stats).
import SwiftUI
import Charts
import SusuCore

public struct StatsScreen: View {
    @EnvironmentObject private var shell: ShellModel
    public init() {}
    public var body: some View { StatsBody(services: shell.services) }
}

private struct StatsBody: View {
    @EnvironmentObject private var shell: ShellModel
    @StateObject private var vm: StatsModel
    @State private var period: StatsPeriod = .month

    init(services: AppServices) { _vm = StateObject(wrappedValue: StatsModel(services: services)) }

    private var s: TableStrings { shell.strings("Stats") }
    private var isEmpty: Bool { vm.snapshot.map { $0.everDictated == 0 } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHead(title: s("sx.title"), subtitle: s("sx.subtitle")) {
                PillTabs(selection: $period, items: StatsPeriod.allCases.map { ($0, s("sx.\($0.key)")) })
                    .disabled(isEmpty).opacity(isEmpty ? 0.5 : 1)
            }
            if let snap = vm.snapshot {
                if snap.everDictated == 0 {
                    emptyState
                } else {
                    ScrollView {
                        StatsContent(snap: snap, vm: vm)
                            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 24)
                    }
                    .scrollIndicators(.never)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: period) { await vm.load(period) }
    }

    private var emptyState: some View {
        VStack(spacing: Space.s3) {
            Image(systemName: "chart.bar").font(.system(size: 32, weight: .light)).foregroundStyle(Palette.ink3)
            Text(s("sx.empty.title")).susuType(.bodyStrong).foregroundStyle(Palette.ink)
            Text(s("sx.empty.hint")).susuType(.body).foregroundStyle(Palette.ink2)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Content

private struct StatsContent: View {
    @EnvironmentObject private var shell: ShellModel
    let snap: StatsSnapshot
    let vm: StatsModel
    private var s: TableStrings { shell.strings("Stats") }
    private var locale: Locale { shell.locale }

    var body: some View {
        CardArea {
            WeightedRow(weights: [1.4, 1, 1, 1], spacing: 12) {
                StatCard(big: true, value: number(snap.totals.words), label: s("sx.words"),
                         delta: percentDelta(snap.totals.words, snap.previous?.words))
                StatCard(value: number(Int(snap.totals.wordsPerMinute.rounded())), label: s("sx.wpm"),
                         delta: wpmDelta())
                StatCard(value: number(snap.totals.dictations), label: s("sx.dictations"),
                         delta: percentDelta(snap.totals.dictations, snap.previous?.dictations))
                // Call recording is not wired to the stats yet: zero hours.
                StatCard(value: number(0), unit: s("sx.hoursUnit"), label: s("sx.callHours"), delta: nil,
                         extra: s.format("sx.callRecords", 0))
            }
            WeightedRow(weights: [1.15, 1], spacing: 12) {
                StreakCard(snap: snap)
                LatencyCard(snap: snap)
            }
            AppsCard(snap: snap, bars: vm.appBars(snap.apps, unknown: s("sx.appsUnknown"), others: s("sx.appsOther")))
            SpendCard(spend: snap.spend)
        }
    }

    private func number(_ n: Int) -> String { n.formatted(.number.locale(locale)) }

    private func percentDelta(_ current: Int, _ previous: Int?) -> StatCard.Delta? {
        guard let previous, previous > 0 else { return nil }
        let pct = Int((Double(current - previous) / Double(previous) * 100).rounded())
        return .init(text: "\(sign(pct))\(abs(pct))% \(s("sx.vs.\(snap.period.key)"))", positive: pct >= 0)
    }

    private func wpmDelta() -> StatCard.Delta? {
        guard let previous = snap.previous, previous.wordsPerMinute > 0 else { return nil }
        let d = Int((snap.totals.wordsPerMinute - previous.wordsPerMinute).rounded())
        return .init(text: "\(sign(d))\(abs(d)) \(s("sx.vs.\(snap.period.key)"))", positive: d >= 0)
    }

    private func sign(_ n: Int) -> String { n < 0 ? "−" : "+" }
}

// MARK: - Stat card

private struct StatCard: View {
    struct Delta { var text: String; var positive: Bool }
    var big = false
    let value: String
    var unit: String?
    let label: String
    let delta: Delta?
    var extra: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: big ? 46 : 34, weight: .semibold).monospacedDigit()).tracking(-0.02 * (big ? 46 : 34))
                    .foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.6)
                if let unit { Text(unit).susuType(.title).foregroundStyle(Palette.ink2) }
            }
            Text(label).susuType(.body).foregroundStyle(Palette.ink2)
            if let delta {
                Text(delta.text).susuType(.caption).foregroundStyle(delta.positive ? Palette.ok : Palette.ink3).padding(.top, 4)
            }
            if let extra { Text(extra).susuType(.caption).foregroundStyle(Palette.ink3).padding(.top, delta == nil ? 4 : 0) }
        }
        .padding(Space.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.bgCard, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .susuShadow(.card, radius: Radius.lg)
    }
}

// MARK: - Streak calendar

private struct StreakCard: View {
    @EnvironmentObject private var shell: ShellModel
    let snap: StatsSnapshot
    private var s: TableStrings { shell.strings("Stats") }
    private var calendar: Calendar { .current }

    private struct Cell: Identifiable {
        let id: Int
        let date: Date
        let inMonth: Bool
        let count: Int
        let future: Bool
        let today: Bool
    }

    var body: some View {
        let cells = makeCells()
        let maxCount = max(1, cells.map(\.count).max() ?? 1)
        TitledCard(s("sx.streak"), accessory: {
            Text(monthLabel).susuType(.small).foregroundStyle(Palette.ink3)
        }) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(snap.streaks.current) \(s.plural(snap.streaks.current, "sx.day"))")
                        .susuType(.number).tracking(-0.7).foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    Text(s.format("sx.record", "\(snap.streaks.longest) \(s.plural(snap.streaks.longest, "sx.day"))"))
                        .susuType(.small).foregroundStyle(Palette.ink3)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(weekdayHeads, id: \.self) { h in
                        Text(h).susuType(.caption).foregroundStyle(Palette.ink3).frame(maxWidth: .infinity)
                    }
                    ForEach(cells) { c in
                        DayCell(cell: c.date, day: calendar.component(.day, from: c.date), level: level(c.count, maxCount),
                                dimmed: !c.inMonth, future: c.future, today: c.today, tip: tip(c))
                    }
                }
                HStack(spacing: 6) {
                    Spacer()
                    Text(s("sx.less")).susuType(.caption).foregroundStyle(Palette.ink3)
                    ForEach(0..<4, id: \.self) { l in LegendSwatch(level: l) }
                    Text(s("sx.more")).susuType(.caption).foregroundStyle(Palette.ink3)
                }
            }
        }
    }

    private var monthLabel: String {
        let f = DateFormatter(); f.locale = shell.locale; f.dateFormat = "LLLL yyyy"
        return f.string(from: AppClock.now)
    }

    private var weekdayHeads: [String] {
        let f = DateFormatter(); f.locale = shell.locale
        let symbols = f.shortStandaloneWeekdaySymbols ?? []
        guard symbols.count == 7 else { return [] }
        return [1, 2, 3, 4, 5, 6, 0].map { symbols[$0] }   // Monday first
    }

    private func level(_ count: Int, _ maxCount: Int) -> Int {
        guard count > 0 else { return 0 }
        let r = Double(count) / Double(maxCount)
        return r <= 0.34 ? 1 : r <= 0.67 ? 2 : 3
    }

    private func tip(_ c: Cell) -> String {
        let f = DateFormatter(); f.locale = shell.locale; f.setLocalizedDateFormatFromTemplate("dMMM")
        let d = f.string(from: c.date)
        return c.count > 0 ? s.format("sx.cell", d, c.count) : s.format("sx.cellNone", d)
    }

    /// The current month, Monday first, padded at the start with the last days of the previous month.
    private func makeCells() -> [Cell] {
        let today = calendar.startOfDay(for: AppClock.now)
        guard let month = calendar.dateInterval(of: .month, for: today),
              let days = calendar.range(of: .day, in: .month, for: today) else { return [] }
        let lead = (calendar.component(.weekday, from: month.start) + 5) % 7
        var out: [Cell] = []
        for i in -lead..<days.count {
            guard let date = calendar.date(byAdding: .day, value: i, to: month.start) else { continue }
            out.append(Cell(id: i, date: date, inMonth: i >= 0, count: snap.dayCounts[date] ?? 0,
                            future: date > today, today: date == today))
        }
        return out
    }
}

private struct DayCell: View {
    let cell: Date
    let day: Int
    let level: Int
    let dimmed: Bool
    let future: Bool
    let today: Bool
    let tip: String

    var body: some View {
        Text("\(day)")
            .font(TypeStyle.small.font.monospacedDigit()).fontWeight(today ? .semibold : .regular)
            .foregroundStyle(level > 0 ? Palette.ink : (future ? Palette.ink3 : Palette.ink2))
            .frame(maxWidth: .infinity).frame(height: 34)
            .background {
                if !future { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(levelColor(level)) }
            }
            .overlay {
                if today { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.accent, lineWidth: 2) }
            }
            .opacity(dimmed ? 0.55 : 1)
            .help(future ? "" : tip)
    }
}

private func levelColor(_ level: Int) -> AnyShapeStyle {
    switch level {
    case 1: AnyShapeStyle(Palette.accent.opacity(0.12))
    case 2: AnyShapeStyle(Palette.accent.opacity(0.26))
    case 3: AnyShapeStyle(Palette.accent.opacity(0.42))
    default: AnyShapeStyle(Palette.bgGroup)
    }
}

private struct LegendSwatch: View {
    let level: Int
    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(levelColor(level)).frame(width: 14, height: 14)
    }
}

// MARK: - Latency

private struct LatencyCard: View {
    @EnvironmentObject private var shell: ShellModel
    let snap: StatsSnapshot
    @State private var selected: Date?
    private var s: TableStrings { shell.strings("Stats") }

    private struct Point: Identifiable { let id: Date; let sec: Double }
    private var points: [Point] { snap.latency.map { Point(id: $0.start, sec: $0.medianMs / 1000) } }

    var body: some View {
        let pts = points
        let median = Self.median(pts.map(\.sec))
        let shown = nearest(to: selected, in: pts) ?? pts.last
        TitledCard(s("sx.latency"), accessory: {
            Text(s(snap.latencyByWeek ? "sx.latency.weeks" : "sx.latency.days")).susuType(.small).foregroundStyle(Palette.ink3)
                .multilineTextAlignment(.trailing).frame(maxWidth: 230, alignment: .trailing)
        }) {
            VStack(alignment: .leading, spacing: 0) {
                if pts.isEmpty {
                    Text(s("sx.latency.none")).susuType(.small).foregroundStyle(Palette.ink3)
                        .frame(maxWidth: .infinity, minHeight: 190, alignment: .center).multilineTextAlignment(.center)
                } else {
                    Text(shown.map(readout) ?? " ").susuType(.caption).fontWeight(.semibold).foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, alignment: .trailing).frame(height: 16)
                    chart(pts, median: median, shown: shown).frame(height: 176)
                }
                Spacer(minLength: 0)
                Text("\(s("sx.median")): \(sec(median)) \(s("sx.sec"))").susuType(.small).foregroundStyle(Palette.ink3)
                    .monospacedDigit().padding(.top, 8).opacity(pts.isEmpty ? 0 : 1)
            }
        }
    }

    private func chart(_ pts: [Point], median: Double, shown: Point?) -> some View {
        let lo = max(0, (((pts.map(\.sec).min() ?? 0) - 0.08) * 10).rounded(.down) / 10)
        let hi = (((pts.map(\.sec).max() ?? 1) + 0.08) * 10).rounded(.up) / 10
        let small = pts.count <= 16
        return Chart {
            RuleMark(y: .value("median", median))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4])).foregroundStyle(Palette.ink3)
            ForEach(pts) { p in
                LineMark(x: .value("day", p.id), y: .value("sec", p.sec))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)).foregroundStyle(Palette.ink2)
                if small {
                    PointMark(x: .value("day", p.id), y: .value("sec", p.sec))
                        .symbolSize(36).foregroundStyle(Palette.ink2)
                }
            }
            if let shown {
                RuleMark(x: .value("day", shown.id)).lineStyle(StrokeStyle(lineWidth: 1)).foregroundStyle(Palette.lineStrong)
                PointMark(x: .value("day", shown.id), y: .value("sec", shown.sec)).symbolSize(60).foregroundStyle(Palette.accent)
            }
        }
        .chartYScale(domain: lo...max(hi, lo + 0.2))
        .chartXSelection(value: $selected)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(Palette.line)
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text("\(sec(d, digits: 1)) \(s("sx.sec"))").font(.system(size: 11)).foregroundStyle(Palette.ink3)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisValueLabel(format: Date.FormatStyle().day().month(.abbreviated).locale(shell.locale))
                    .font(.system(size: 11)).foregroundStyle(Palette.ink3)
            }
        }
    }

    private func nearest(to date: Date?, in pts: [Point]) -> Point? {
        guard let date else { return nil }
        return pts.min { abs($0.id.timeIntervalSince(date)) < abs($1.id.timeIntervalSince(date)) }
    }

    private func readout(_ p: Point) -> String {
        let f = DateFormatter(); f.locale = shell.locale; f.setLocalizedDateFormatFromTemplate("dMMM")
        let day = f.string(from: p.id)
        let label = snap.latencyByWeek ? s.format("sx.weekFrom", day) : day
        return "\(label) · \(sec(p.sec)) \(s("sx.sec"))"
    }

    private func sec(_ v: Double, digits: Int = 2) -> String {
        v.formatted(.number.precision(.fractionLength(digits)).locale(shell.locale))
    }

    static func median(_ v: [Double]) -> Double {
        let a = v.sorted()
        guard !a.isEmpty else { return 0 }
        return a.count % 2 == 1 ? a[a.count / 2] : (a[a.count / 2 - 1] + a[a.count / 2]) / 2
    }
}

// MARK: - Apps

private struct AppsCard: View {
    @EnvironmentObject private var shell: ShellModel
    let snap: StatsSnapshot
    let bars: [AppBarItem]
    @State private var hovered: String?
    private var s: TableStrings { shell.strings("Stats") }

    var body: some View {
        let maxValue = max(1, bars.map(\.dictations).max() ?? 1)
        let total = max(1, bars.reduce(0) { $0 + $1.dictations })
        let active = hovered ?? bars.first?.id
        TitledCard(s("sx.apps"), accessory: {
            Text(s("sx.for.\(snap.period.key)")).susuType(.small).foregroundStyle(Palette.ink3)
        }) {
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(bars) { bar in
                    let on = bar.id == active
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        Text(bar.dictations.formatted(.number.locale(shell.locale)))
                            .susuType(.caption).monospacedDigit().fontWeight(on ? .semibold : .medium)
                            .foregroundStyle(on ? Palette.ink : Palette.ink2)
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(on ? Palette.accent : Palette.bgFill)
                            .frame(width: 36, height: max(4, 130 * CGFloat(bar.dictations) / CGFloat(maxValue)))
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 4, bottomTrailingRadius: 4, topTrailingRadius: 8,
                                                              style: .continuous))
                        Text(bar.name).susuType(.caption).foregroundStyle(Palette.ink3).lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { inside in hovered = inside ? bar.id : (hovered == bar.id ? nil : hovered) }
                    .help("\(bar.name): \(bar.dictations.formatted(.number.locale(shell.locale))) (\(Int((Double(bar.dictations) / Double(total) * 100).rounded()))%)")
                }
            }
            .frame(height: 210)
            .susuAnimation(Motion.fast, value: active)
        }
    }
}

// MARK: - Spend

private struct SpendCard: View {
    @EnvironmentObject private var shell: ShellModel
    let spend: [SpendLog.ProviderTotal]
    private var s: TableStrings { shell.strings("Stats") }

    var body: some View {
        let total = spend.reduce(0) { $0 + $1.costUsd }
        TitledCard(s("sx.spend"), accessory: {
            Text(s("sx.spend.month")).susuType(.small).foregroundStyle(Palette.ink3)
        }) {
            if spend.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").font(.system(size: 20, weight: .light)).foregroundStyle(Palette.ok)
                    Text(s("sx.spend.none")).susuType(.body).foregroundStyle(Palette.ink2)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(spend.enumerated()), id: \.offset) { i, row in
                        SpendRow(title: providerName(row.provider), detail: providerDetail(row.provider),
                                 share: total > 0 ? row.costUsd / total : 0, amount: money(row.costUsd), first: i == 0)
                    }
                    SpendRow(title: s("sx.spend.total"), detail: nil, share: nil, amount: money(total), first: false)
                }
                .padding(.horizontal, 24)
                .background(Palette.bgGroup, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            }
        }
    }

    private func providerName(_ id: String) -> String {
        switch id {
        case "groq": "Groq"
        case "openrouter": "OpenRouter"
        case "": "—"
        default: id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    private func providerDetail(_ id: String) -> String? {
        id == "groq" || id == "openrouter" ? s("sx.spend.\(id)") : nil
    }

    private func money(_ v: Double) -> String {
        "$" + v.formatted(.number.precision(.fractionLength(2)).locale(shell.locale))
    }
}

private struct SpendRow: View {
    let title: String
    let detail: String?
    let share: Double?
    let amount: String
    let first: Bool

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).susuType(.bodyStrong).foregroundStyle(Palette.ink)
                if let detail { Text(detail).susuType(.body).foregroundStyle(Palette.ink2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let share {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.bgFill)
                        Capsule().fill(Palette.ink2).frame(width: max(4, g.size.width * share))
                    }
                }
                .frame(width: 160, height: 4)
            }
            Text(amount).susuType(.bodyStrong).monospacedDigit().foregroundStyle(Palette.ink)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.vertical, Space.s4)
        .frame(minHeight: 60)
        .overlay(alignment: .top) { if !first { Rectangle().fill(Palette.line).frame(height: 1) } }
    }
}

// MARK: - Previews

@MainActor
private func sampleShell(language: InterfaceLanguage = .ru) -> ShellModel {
    let services = AppServices.temporary()
    _ = try? services.settings.update { $0.interfaceLanguage = language }
    let cal = Calendar.current
    let now = Date()
    var rows: [Dictation] = []
    let apps: [(String, String)] = [("com.todesktop.230313mzl4w4u92", "Cursor"), ("ru.keepcoder.Telegram", "Telegram"),
                                    ("com.google.Chrome", "Chrome"), ("notion.id", "Notion")]
    for day in 0..<40 where day % 7 != 3 {
        for n in 0..<(2 + (day * 5) % 9) {
            let t = cal.date(byAdding: .minute, value: -(day * 1440 + n * 37), to: now) ?? now
            let a = apps[(day + n) % apps.count]
            rows.append(Dictation(createdAt: t, durationMs: 4000 + n * 700, appName: a.1, bundleId: a.0,
                                  rawText: "раз два три четыре пять шесть семь восемь", latencyMs: 380 + (day * 37 + n * 11) % 260))
        }
    }
    Task {
        try? await services.history.save(rows)
        _ = try? await services.spend.recordAudio(task: "stt", provider: .groq, model: "whisper-large-v3-turbo", audioSeconds: 3600 * 4)
        _ = try? await services.spend.recordChat(task: "edit", provider: .openRouter, model: "x",
                                                 usage: Usage(promptTokens: 1_000_000, completionTokens: 100_000, costUSD: 0.62))
    }
    return ShellModel(services: services)
}

#Preview("Stats, light") {
    StatsScreen().shellRoot(sampleShell())
        .frame(width: 950, height: 900).background(Palette.bgCard).preferredColorScheme(.light)
}

#Preview("Stats, dark") {
    StatsScreen().shellRoot(sampleShell())
        .frame(width: 950, height: 900).background(Palette.bgCard).preferredColorScheme(.dark)
}

#Preview("Stats, empty") {
    StatsScreen().shellRoot(ShellModel(services: .temporary()))
        .frame(width: 950, height: 600).background(Palette.bgCard)
}
