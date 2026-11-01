// SPDX-License-Identifier: MIT
import Foundation

/// The Agents space's period for cost and tokens.
public enum UsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case today, week, month, all

    public var id: Self { self }

    public var title: String {
        switch self {
        case .today: "Today"
        case .week: "7 Days"
        case .month: "30 Days"
        case .all: "All"
        }
    }

    /// The first day inside the period as a `yyyy-MM-dd` key, counting today; nil for All, which has none.
    func firstDay(now: Date, calendar: Calendar = .current) -> String? {
        let back: Int
        switch self {
        case .today: back = 0
        case .week: back = 6
        case .month: back = 29
        case .all: return nil
        }
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -back, to: start).map {
            DailyUsageAccumulator.dayKey(from: $0, calendar: calendar)
        }
    }
}

/// What one tool used in a period.
struct ToolUsage: Identifiable, Equatable {
    let id: String
    let name: String
    let tokens: Int
    /// Dollars at API prices; nil when none of the tokens could be priced.
    let cost: Double?
}

/// One day's tokens and cost across the tools, for the bars of the last 30 days.
struct DaySpend: Equatable {
    /// The start of the day.
    let date: Date
    let tokens: Int
    /// Zero for a day with none, or with no price.
    let cost: Double
}

/// One tool's row of the table: what it used and what is left of its quota, level with each other.
struct ToolRow: Identifiable, Equatable {
    let id: String
    let name: String
    /// Nil when the tool used nothing in the period.
    let usage: ToolUsage?
    /// Nil when the tool has no quota to show.
    let quota: QuotaBlock?

    /// How many lines the quota needs: one for each window and one for each named pool's caption, one for a
    /// state, none without a block.
    var quotaLines: Int {
        guard let quota else { return 0 }
        if case .rows(let pools) = quota.state { return pools.reduce(0) { $0 + $1.lines } }
        return 1
    }

    var height: Double { AgentsUsage.rowHeight(lines: quotaLines) }
}

/// One quota row of a provider: 5 hours, a week or a month.
struct QuotaRow: Identifiable, Equatable {
    enum Kind: Int, Comparable {
        case fiveHour, week, month

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .fiveHour: "5h"
            case .week: "W"
            case .month: "M"
            }
        }
    }

    let kind: Kind
    /// How much is left, 0...1.
    let left: Double
    /// Time to the reset, as "3h 12m"; nil when the provider says none.
    let reset: String?
    /// Where even use would have the bar by now, 0...1 of the bar; nil when the window's length is not known.
    let pace: Double?

    var id: Kind { kind }
}

/// Quota rows that draw on one allowance: a tool's main pool, or an extra one such as Antigravity's Claude.
struct QuotaPool: Identifiable, Equatable {
    /// Nil for the main pool, and for the only pool of a tool.
    let name: String?
    let rows: [QuotaRow]

    var id: String { name ?? "" }
    /// A named pool has its name on a line of its own above its rows.
    var lines: Int { rows.count + (name == nil ? 0 : 1) }
}

/// A provider's block of quota pools, or the short state in their place.
struct QuotaBlock: Identifiable, Equatable {
    enum State: Equatable {
        case rows([QuotaPool])
        case checking
        /// Its tool is not signed in: its own sign-in is what fixes it.
        case signIn
        case unavailable
    }

    let id: String
    let name: String
    let state: State
    /// Why a state is what it is, for its tooltip.
    let detail: String?
}

enum AgentsUsage {
    // MARK: Layout

    /// The width below which the narrower columns are used: Now's breakpoint.
    static let narrow = 660.0

    /// The widths of the left and middle columns; the right takes the rest.
    static func columns(width: Double) -> (left: Double, middle: Double) {
        width < narrow ? (150, 192) : (176, 214)
    }

    /// A table row is as tall as its quota needs, two lines at least, so spend and quota stay level.
    static func rowHeight(lines: Int) -> Double { 9 + 17 * Double(max(2, lines)) }

    /// The table: the tools with usage in the order given, then the tools that have a quota but no usage.
    static func table(tools: [ToolUsage], blocks: [QuotaBlock]) -> [ToolRow] {
        let quotas = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let used = tools.map { ToolRow(id: $0.id, name: $0.name, usage: $0, quota: quotas[$0.id]) }
        let seen = Set(tools.map(\.id))
        return used
            + blocks.filter { !seen.contains($0.id) }.map { ToolRow(id: $0.id, name: $0.name, usage: nil, quota: $0) }
    }

    // MARK: Cost and tokens

    /// The tools with usage in `period`, the dearest first. A tool whose models could not be priced still
    /// shows its tokens, with no cost.
    static func tools(
        snapshots: [String: ProviderSnapshot], providers: [UsageProvider], period: UsagePeriod, now: Date = .now,
        calendar: Calendar = .current
    ) -> [ToolUsage] {
        let first = period.firstDay(now: now, calendar: calendar)
        let last = DailyUsageAccumulator.dayKey(from: now, calendar: calendar)
        let found = providers.compactMap { provider -> ToolUsage? in
            guard let days = snapshots[provider.id]?.usageHistory?.series.daily else { return nil }
            var tokens = 0
            var cost: Double?
            for day in days {
                let key = String(day.date.prefix(10))
                if let first, key < first { continue }
                if key > last { continue }
                tokens += day.totalTokens
                if let value = day.costUSD { cost = (cost ?? 0) + value }
            }
            return tokens > 0 || (cost ?? 0) > 0
                ? ToolUsage(id: provider.id, name: provider.name, tokens: tokens, cost: cost) : nil
        }
        return found.sorted { ($0.cost ?? -1, $0.tokens) > ($1.cost ?? -1, $1.tokens) }
    }

    /// The segments of the share bar, each tool's share of the total, in the order given. By cost where any tool has
    /// one, else by tokens.
    static func shares(_ tools: [ToolUsage]) -> [(id: String, fraction: Double)] {
        let byCost = tools.contains { ($0.cost ?? 0) > 0 }
        let weights = tools.map { byCost ? ($0.cost ?? 0) : Double($0.tokens) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }
        return zip(tools, weights).filter { $0.1 > 0 }.map { ($0.0.id, $0.1 / total) }
    }

    /// What the tools cost together, nil when none of them has a price; and their tokens.
    static func totals(_ tools: [ToolUsage]) -> (cost: Double?, tokens: Int) {
        let cost = tools.reduce(0) { $0 + ($1.cost ?? 0) }
        return (cost > 0 ? cost : nil, tools.reduce(0) { $0 + $1.tokens })
    }

    /// The last `count` days across `providers`, oldest first, ending today; a day with no usage is zero.
    static func daily(
        snapshots: [String: ProviderSnapshot], providers: [UsageProvider], count: Int = 30, now: Date = .now,
        calendar: Calendar = .current
    ) -> [DaySpend] {
        var byDay: [String: (tokens: Int, cost: Double)] = [:]
        for provider in providers {
            for day in snapshots[provider.id]?.usageHistory?.series.daily ?? [] {
                let key = String(day.date.prefix(10))
                byDay[key, default: (0, 0)].tokens += day.totalTokens
                byDay[key, default: (0, 0)].cost += day.costUSD ?? 0
            }
        }
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: today).map { date in
                let total = byDay[DailyUsageAccumulator.dayKey(from: date, calendar: calendar)] ?? (0, 0)
                return DaySpend(date: date, tokens: total.tokens, cost: total.cost)
            }
        }
    }

    /// The days a period spans, counting today: one, 7 or 30; for All, from the first day with any usage.
    static func days(
        in period: UsagePeriod, snapshots: [String: ProviderSnapshot], providers: [UsageProvider], now: Date = .now,
        calendar: Calendar = .current
    ) -> Int {
        switch period {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        case .all:
            let today = calendar.startOfDay(for: now)
            let last = DailyUsageAccumulator.dayKey(from: today, calendar: calendar)
            var first: String?
            for provider in providers {
                for day in snapshots[provider.id]?.usageHistory?.series.daily ?? [] {
                    let key = String(day.date.prefix(10))
                    guard day.totalTokens > 0 || (day.costUSD ?? 0) > 0, key <= last else { continue }
                    if first == nil || key < first! { first = key }
                }
            }
            let parts = first?.split(separator: "-").compactMap { Int($0) } ?? []
            guard parts.count == 3,
                let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                let days = calendar.dateComponents([.day], from: start, to: today).day
            else { return 1 }
            return max(days + 1, 1)
        }
    }

    // MARK: Quota

    /// Which quota a meter is: by the length of its window where the provider gives one, else by its name.
    static func kind(of meter: Meter) -> QuotaRow.Kind? {
        if let period = meter.period, period > 0 {
            let hours = period / 3600
            if hours >= 4, hours <= 6 { return .fiveHour }
            if hours >= 6 * 24, hours <= 8 * 24 { return .week }
            if hours >= 27 * 24, hours <= 32 * 24 { return .month }
            return nil
        }
        let label = meter.label.lowercased()
        if label.contains("session") || label.contains("5-hour") || label.contains("5 hour") { return .fiveHour }
        if label.contains("week") { return .week }
        if label.contains("month") { return .month }
        return nil
    }

    /// The pool a meter belongs to: its label less the window words ("Claude Weekly" is "Claude"). Nil for the
    /// main pool, whose labels are only window words ("Session", "Weekly limit", "Daily quota").
    static func poolName(of label: String) -> String? {
        let words = #"(?i)\b(session|weekly|week|monthly|month|5[- ]hour|daily|quota|limit)\b"#
        let name = label.replacingOccurrences(of: words, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    private typealias Entry = (name: String?, kind: QuotaRow.Kind, meter: Meter)

    /// A provider's quota pools: the main one first, then the others in the provider's order. A named pool is one
    /// with a 5-hour window (Antigravity's Claude, Codex's Spark); any other meter, like Claude's Sonnet or
    /// Cursor's On-demand, joins the main pool. Within a pool, one row for each kind in the order 5h, W, M, from
    /// the first meter of that kind. A tool with one pool shows it unnamed.
    static func pools(from meters: [Meter], now: Date) -> [QuotaPool] {
        let found = meters.compactMap { meter in
            kind(of: meter).map { (name: poolName(of: meter.label), kind: $0, meter: meter) as Entry }
        }
        var named: [String] = []
        for case (let name?, .fiveHour, _) in found where !named.contains(name) { named.append(name) }
        func pool(_ name: String?, _ entries: [Entry]) -> QuotaPool? {
            var seen: Set<QuotaRow.Kind> = []
            let rows = entries.compactMap { entry in
                seen.insert(entry.kind).inserted ? row(entry.meter, entry.kind, now: now) : nil
            }
            return rows.isEmpty ? nil : QuotaPool(name: name, rows: rows.sorted { $0.kind < $1.kind })
        }
        let main = pool(nil, found.filter { $0.name.map { !named.contains($0) } ?? true })
        let pools = [main].compactMap { $0 } + named.compactMap { name in pool(name, found.filter { $0.name == name }) }
        return pools.count == 1 ? [QuotaPool(name: nil, rows: pools[0].rows)] : pools
    }

    private static func row(_ meter: Meter, _ kind: QuotaRow.Kind, now: Date) -> QuotaRow {
        let left = min(max(1 - meter.fraction, 0), 1)
        let remaining = meter.resetsAt.map { max($0.timeIntervalSince(now), 0) }
        var pace: Double?
        if let remaining, let period = meter.period, period > 0 { pace = min(remaining / period, 1) }
        return QuotaRow(kind: kind, left: left, reset: remaining.map(resetText), pace: pace)
    }

    /// "3h 12m", "4d 8h", "42m".
    static func resetText(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 24 * 60 { return "\(minutes / (24 * 60))d \(minutes / 60 % 24)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(max(minutes, 0))m"
    }

    /// The blocks to show: every provider that is on and has quota rows, or the short state of one that
    /// cannot be read. A provider that has only spend, or nothing to say yet, has no block.
    static func blocks(
        providers: [UsageProvider], snapshots: [String: ProviderSnapshot], errors: [String: String],
        categories: [String: ErrorCategory], now: Date
    ) -> [QuotaBlock] {
        providers.compactMap { provider -> QuotaBlock? in
            let pools = snapshots[provider.id].map { AgentsUsage.pools(from: $0.meters, now: now) } ?? []
            if !pools.isEmpty {
                return QuotaBlock(
                    id: provider.id, name: provider.name, state: .rows(pools), detail: errors[provider.id])
            }
            if let message = errors[provider.id] {
                let signIn = [.notLoggedIn, .authExpired, .authInvalid].contains(categories[provider.id])
                return QuotaBlock(
                    id: provider.id, name: provider.name, state: signIn ? .signIn : .unavailable, detail: message)
            }
            if snapshots[provider.id] == nil {
                return QuotaBlock(id: provider.id, name: provider.name, state: .checking, detail: nil)
            }
            return nil
        }
    }
}

/// The numbers of the Agents space, as words.
enum AgentsFormat {
    /// Under 1,000 as it is; then "850k", "18.2M", "1.2B" and "3.4T": whole thousands, then a decimal under
    /// a hundred from a million on.
    static func tokens(_ count: Int) -> String {
        guard count >= 1000 else { return "\(max(count, 0))" }
        let thousands = Double(count) / 1000
        if thousands.rounded() < 1000 { return "\(Int(thousands.rounded()))k" }
        let units = ["M", "B", "T"]
        var value = thousands / 1000
        var unit = 0
        while unit < units.count - 1, value >= 999.5 {
            value /= 1000
            unit += 1
        }
        return value >= 99.95 ? "\(Int(value.rounded()))\(units[unit])" : String(format: "%.1f%@", value, units[unit])
    }

    /// "$241.60", with thousands set apart.
    static func cost(_ dollars: Double) -> String {
        dollars.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }

    /// "$4,178": whole dollars, for the large figure.
    static func wholeCost(_ dollars: Double) -> String {
        dollars.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")).precision(.fractionLength(0)))
    }

    /// How long since a session last moved: "now" under a minute, then "2m", "1h", "3d".
    static func elapsed(since date: Date, now: Date) -> String {
        let minutes = Int(max(now.timeIntervalSince(date), 0) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return "\(minutes / 60)h" }
        return "\(minutes / (24 * 60))d"
    }
}
