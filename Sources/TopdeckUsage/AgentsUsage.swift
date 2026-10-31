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

/// A provider's block of quota rows, or the short state in their place.
struct QuotaBlock: Identifiable, Equatable {
    enum State: Equatable {
        case rows([QuotaRow])
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

    /// The slices of the donut, each tool's share of the total, in the order given. By cost where any tool has
    /// one, else by tokens.
    static func shares(_ tools: [ToolUsage]) -> [(id: String, fraction: Double)] {
        let byCost = tools.contains { ($0.cost ?? 0) > 0 }
        let weights = tools.map { byCost ? ($0.cost ?? 0) : Double($0.tokens) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }
        return zip(tools, weights).filter { $0.1 > 0 }.map { ($0.0.id, $0.1 / total) }
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

    /// A provider's quota rows, one for each kind in the order 5h, W, M, from the first meter of that kind.
    static func rows(from meters: [Meter], now: Date) -> [QuotaRow] {
        var seen: Set<QuotaRow.Kind> = []
        var rows: [QuotaRow] = []
        for meter in meters {
            guard let kind = kind(of: meter), seen.insert(kind).inserted else { continue }
            let left = min(max(1 - meter.fraction, 0), 1)
            let remaining = meter.resetsAt.map { max($0.timeIntervalSince(now), 0) }
            var pace: Double?
            if let remaining, let period = meter.period, period > 0 { pace = min(remaining / period, 1) }
            rows.append(QuotaRow(kind: kind, left: left, reset: remaining.map(resetText), pace: pace))
        }
        return rows.sorted { $0.kind < $1.kind }
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
            let rows = snapshots[provider.id].map { rows(from: $0.meters, now: now) } ?? []
            if !rows.isEmpty {
                return QuotaBlock(id: provider.id, name: provider.name, state: .rows(rows), detail: errors[provider.id])
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

    /// In the donut: "$328", "$1.2K", "$12K", under ten dollars with its cents.
    static func donutCost(_ dollars: Double) -> String {
        if dollars < 10 { return String(format: "$%.2f", dollars) }
        if dollars < 1000 { return String(format: "$%.0f", dollars) }
        var value = dollars / 1000
        var unit = "K"
        if value >= 999.5 {
            value /= 1000
            unit = "M"
        }
        return value >= 9.95 ? String(format: "$%.0f%@", value, unit) : String(format: "$%.1f%@", value, unit)
    }
}
