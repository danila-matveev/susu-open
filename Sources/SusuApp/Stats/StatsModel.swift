// Loads the numbers of the Stats screen for one period. All SQL lives in `StatsQueries`.
import SwiftUI
import SusuCore

enum StatsPeriod: Hashable, CaseIterable {
    case week, month, all
    var key: String {
        switch self { case .week: "week"; case .month: "month"; case .all: "all" }
    }
}

struct AppBarItem: Identifiable, Equatable {
    let id: String
    let name: String
    let dictations: Int
}

struct StatsSnapshot {
    var period: StatsPeriod
    var totals: StatsQueries.Totals
    /// Same-length window before the period; nil for "all time".
    var previous: StatsQueries.Totals?
    var apps: [StatsQueries.AppCount]
    var latency: [StatsQueries.LatencyPoint]
    var latencyByWeek: Bool
    var dayCounts: [Date: Int]
    var streaks: StatsQueries.Streaks
    var spend: [SpendLog.ProviderTotal]
    /// Dictations ever recorded: 0 shows the empty state.
    var everDictated: Int
}

@MainActor
final class StatsModel: ObservableObject {
    @Published private(set) var snapshot: StatsSnapshot?
    private let services: AppServices
    private let queries: StatsQueries

    init(services: AppServices) {
        self.services = services
        queries = StatsQueries(database: services.database)
    }

    func load(_ period: StatsPeriod, now: Date = AppClock.now, calendar: Calendar = .current) async {
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }
        let end = day(1)

        let from: Date?, previousFrom: Date?
        switch period {
        case .week: from = day(-6); previousFrom = day(-13)
        case .month: from = day(-29); previousFrom = day(-59)
        case .all: from = nil; previousFrom = nil
        }
        let weekly = period == .all
        let latencyFrom = weekly ? day(-26 * 7) : (from ?? day(-29))

        do {
            let totals = try await queries.totals(from: from, to: end)
            let overall = period == .all ? totals : try await queries.totals()
            let previous: StatsQueries.Totals? = if let from, let previousFrom {
                try await queries.totals(from: previousFrom, to: from)
            } else { nil }
            let counts = try await queries.dayCounts(calendar: calendar)
            snapshot = StatsSnapshot(
                period: period, totals: totals, previous: previous,
                apps: try await queries.dictationsByApp(from: from, to: end),
                latency: try await queries.medianLatency(from: latencyFrom, to: end, bucket: weekly ? .week : .day, calendar: calendar),
                latencyByWeek: weekly,
                dayCounts: counts,
                streaks: StatsQueries.streaks(dayCounts: counts, calendar: calendar, now: now),
                spend: try await services.spend.monthlyTotals(month: now, calendar: calendar),
                everDictated: overall.dictations)
        } catch {
            // A failed read leaves the previous numbers on screen.
        }
    }

    /// Top 7 apps by dictations plus «Другие»; names come from the installed app, else from history.
    func appBars(_ counts: [StatsQueries.AppCount], unknown: String, others: String) -> [AppBarItem] {
        func item(_ c: StatsQueries.AppCount, _ i: Int) -> AppBarItem {
            let name = c.bundleId.flatMap { AppCatalog.installedName($0) } ?? c.appName ?? c.bundleId ?? unknown
            return AppBarItem(id: "\(i)-\(c.bundleId ?? c.appName ?? "")", name: name, dictations: c.dictations)
        }
        let top = counts.prefix(7).enumerated().map { item($1, $0) }
        let rest = counts.dropFirst(7).reduce(0) { $0 + $1.dictations }
        return rest > 0 ? top + [AppBarItem(id: "others", name: others, dictations: rest)] : top
    }
}
