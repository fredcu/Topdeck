// SPDX-License-Identifier: MIT
import Foundation

@testable import TopdeckUsage

/// Sample usage like the Agents board's: tools with a month of tokens and cost, and quota windows at levels.
@MainActor
enum AgentsSample {
    struct Window {
        var label: String
        var left: Double
        var hours: Double
        var resetsIn: TimeInterval
    }

    static let calendar = Calendar.current

    /// A month of daily usage ending today, even across the days.
    static func history(tokens: Int, cost: Double?, days: Int = 30, now: Date) -> ProviderUsageHistory {
        let entries = (0..<days).map { back -> DailyUsageEntry in
            let day = calendar.date(byAdding: .day, value: -back, to: now)!
            return DailyUsageEntry(
                date: DailyUsageAccumulator.dayKey(from: day), totalTokens: tokens / days,
                costUSD: cost.map { $0 / Double(days) })
        }
        return ProviderUsageHistory(series: DailyUsageSeries(daily: entries))
    }

    static func snapshot(
        _ id: String, _ name: String, tokens: Int = 0, cost: Double? = nil, windows: [Window] = [], now: Date = .now
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id, displayName: name,
            lines: windows.map {
                .progress(
                    label: $0.label, used: (1 - $0.left) * 100, limit: 100, format: .percent,
                    resetsAt: now.addingTimeInterval($0.resetsIn), periodDurationMs: Int($0.hours * 3_600_000))
            },
            refreshedAt: now, usageHistory: tokens > 0 ? history(tokens: tokens, cost: cost, now: now) : nil)
    }

    static let fiveHours = 5.0
    static let week = 7.0 * 24
    static let month = 30.0 * 24

    /// The board's four-and-a-half tools.
    static func board(now: Date = .now) -> [ProviderSnapshot] {
        [
            snapshot(
                "claude", "Claude", tokens: 18_200_000, cost: 241.60,
                windows: [
                    Window(label: "Session", left: 0.73, hours: fiveHours, resetsIn: 3 * 3600 + 12 * 60),
                    Window(label: "Weekly", left: 0.42, hours: week, resetsIn: 4 * 86_400 + 8 * 3600),
                ], now: now),
            snapshot(
                "antigravity", "Antigravity", tokens: 3_100_000, cost: 19.40,
                windows: [
                    Window(label: "Session", left: 0.92, hours: fiveHours, resetsIn: 2 * 3600 + 20 * 60),
                    Window(label: "Weekly", left: 0.77, hours: week, resetsIn: 3 * 86_400 + 4 * 3600),
                ], now: now),
            snapshot(
                "codex", "Codex", tokens: 6_400_000, cost: 58.12,
                windows: [
                    Window(label: "Session", left: 0.84, hours: fiveHours, resetsIn: 3600 + 46 * 60),
                    Window(label: "Weekly", left: 0.61, hours: week, resetsIn: 5 * 86_400 + 2 * 3600),
                ], now: now),
            snapshot(
                "cline", "Cline", tokens: 1_200_000, cost: 8.75,
                windows: [
                    Window(label: "5-hour", left: 1, hours: fiveHours, resetsIn: 4 * 3600 + 41 * 60),
                    Window(label: "Weekly", left: 0.77, hours: week, resetsIn: 5 * 86_400 + 18 * 3600),
                    Window(label: "Monthly", left: 0.89, hours: month, resetsIn: 22 * 86_400 + 4 * 3600),
                ], now: now),
            snapshot(
                "grok", "Grok",
                windows: [Window(label: "Weekly limit", left: 0.58, hours: week, resetsIn: 2 * 86_400 + 6 * 3600)],
                now: now),
        ]
    }

    /// A feature with `snapshots` on, in order, and nothing to ask.
    static func usage(
        _ snapshots: [ProviderSnapshot], defaults: UserDefaults, cache: URL, offered: [(String, String)] = []
    ) throws -> UsageFeature {
        let cached = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.providerID, $0) })
        try JSONEncoder().encode(cached).write(to: cache)
        defaults.set(snapshots.map(\.providerID), forKey: "usage.enabledProviders")
        let runtimes = (snapshots.map { ($0.providerID, $0.displayName) } + offered).map {
            FakeRuntime(id: $0.0, name: $0.1, used: 0)
        }
        return UsageFeature(defaults: defaults, cacheURL: cache, runtimes: { runtimes })
    }
}
