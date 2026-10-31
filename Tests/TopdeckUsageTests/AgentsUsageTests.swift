// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import TopdeckUsage

struct AgentsFormatTests {
    @Test func tokensReadAsShortAsTheBoardsAndNeverAsThousandsOfMillions() {
        let cases: [(Int, String)] = [
            (0, "0"), (999, "999"), (1000, "1k"), (1499, "1k"), (850_000, "850k"), (999_499, "999k"),
            (999_500, "1.0M"), (1_200_000, "1.2M"), (6_400_000, "6.4M"), (18_200_000, "18.2M"),
            (99_949_999, "99.9M"), (99_950_000, "100M"), (850_000_000, "850M"), (999_499_999, "999M"),
            (999_500_000, "1.0B"), (1_200_000_000, "1.2B"), (12_300_000_000, "12.3B"), (850_000_000_000, "850B"),
            (999_500_000_000, "1.0T"), (3_400_000_000_000, "3.4T"), (1_234_000_000_000_000, "1234T"),
        ]
        for (count, text) in cases { #expect(AgentsFormat.tokens(count) == text, "\(count)") }
    }

    @Test func costsHaveCentsInRowsAndStayShortInTheDonut() {
        #expect(AgentsFormat.cost(241.6) == "$241.60" && AgentsFormat.cost(8.75) == "$8.75")
        #expect(AgentsFormat.cost(1234.5) == "$1,234.50")
        #expect(AgentsFormat.donutCost(328.4) == "$328" && AgentsFormat.donutCost(327.6) == "$328")
        #expect(AgentsFormat.donutCost(1234) == "$1.2K" && AgentsFormat.donutCost(12_345) == "$12K")
        #expect(AgentsFormat.donutCost(999_600) == "$1.0M" && AgentsFormat.donutCost(4.5) == "$4.50")
        #expect(AgentsFormat.donutCost(0) == "$0.00")
    }
}

@MainActor
struct AgentsUsageTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let now = Date(timeIntervalSince1970: 1_793_000_000)  // 2026-10-26 07:33 UTC

    private func key(_ back: Int) -> String {
        DailyUsageAccumulator.dayKey(
            from: Self.calendar.date(byAdding: .day, value: -back, to: now)!, calendar: Self.calendar)
    }

    private func snapshot(_ id: String, _ days: [(Int, Int, Double?)]) -> ProviderSnapshot {
        let series = DailyUsageSeries(
            daily: days.map { DailyUsageEntry(date: key($0.0), totalTokens: $0.1, costUSD: $0.2) })
        return ProviderSnapshot(
            providerID: id, displayName: id.capitalized, lines: [], usageHistory: ProviderUsageHistory(series: series))
    }

    private func provider(_ id: String) -> UsageProvider { UsageProvider(id: id, name: id.capitalized, dashboard: nil) }

    @Test func eachPeriodStartsOnItsFirstDayAndAllHasNone() {
        #expect(UsagePeriod.today.firstDay(now: now, calendar: Self.calendar) == key(0))
        #expect(UsagePeriod.week.firstDay(now: now, calendar: Self.calendar) == key(6))
        #expect(UsagePeriod.month.firstDay(now: now, calendar: Self.calendar) == key(29))
        #expect(UsagePeriod.all.firstDay(now: now, calendar: Self.calendar) == nil)
        #expect(UsagePeriod.allCases.map(\.title) == ["Today", "7 Days", "30 Days", "All"])
    }

    @Test func aToolsUsageIsWhatFallsInThePeriodAndAllHoldsEverythingTheLogsDo() {
        let snapshots = [
            "claude": snapshot("claude", [(0, 100, 1), (3, 200, 2), (10, 400, 4), (200, 800, 8)]),
            "codex": snapshot("codex", [(1, 50, 5)]),
            "idle": snapshot("idle", [(0, 0, 0)]),
        ]
        let providers = ["claude", "codex", "idle", "absent"].map(provider)
        func tools(_ period: UsagePeriod) -> [ToolUsage] {
            AgentsUsage.tools(
                snapshots: snapshots, providers: providers, period: period, now: now, calendar: Self.calendar)
        }
        #expect(tools(.today).map(\.id) == ["claude"] && tools(.today)[0].tokens == 100)
        #expect(tools(.week).map(\.id) == ["codex", "claude"], "the dearer first")
        #expect(tools(.week)[1].tokens == 300 && tools(.week)[1].cost == 3)
        #expect(tools(.month).map(\.tokens) == [700, 50])
        #expect(tools(.all).map(\.tokens) == [1500, 50], "all is every day the logs hold")
        #expect(tools(.all)[0].cost == 15 && tools(.all)[0].name == "Claude")
    }

    @Test func aFutureDayAndAnUnpricedToolAreHandledAsTheyAre() {
        let snapshots = [
            "claude": snapshot("claude", [(-2, 999, 9), (0, 10, nil)]),
            "grok": snapshot("grok", [(0, 40, 0.5)]),
        ]
        let tools = AgentsUsage.tools(
            snapshots: snapshots, providers: ["claude", "grok"].map(provider), period: .month, now: now,
            calendar: Self.calendar)
        #expect(tools.map(\.id) == ["grok", "claude"], "a priced tool before an unpriced one")
        #expect(tools[1].tokens == 10 && tools[1].cost == nil, "tokens without a price are not a price of zero")
    }

    @Test func theDonutSlicesByCostElseByTokens() {
        let a = ToolUsage(id: "a", name: "A", tokens: 100, cost: 75)
        let b = ToolUsage(id: "b", name: "B", tokens: 900, cost: 25)
        #expect(AgentsUsage.shares([a, b]).map(\.fraction) == [0.75, 0.25])
        let c = ToolUsage(id: "c", name: "C", tokens: 300, cost: nil)
        let d = ToolUsage(id: "d", name: "D", tokens: 100, cost: nil)
        #expect(AgentsUsage.shares([c, d]).map(\.fraction) == [0.75, 0.25], "no prices at all: by tokens")
        #expect(AgentsUsage.shares([]).isEmpty)
    }

    private func meter(_ label: String, used: Double, hours: Double?, resetsIn: TimeInterval? = nil) -> Meter {
        Meter(
            label: label, used: used, limit: 100, format: .percent,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) },
            period: hours.map { $0 * 3600 })
    }

    @Test func aMeterIsAQuotaByTheLengthOfItsWindowElseByItsName() {
        #expect(AgentsUsage.kind(of: meter("Session", used: 1, hours: 5)) == .fiveHour)
        #expect(AgentsUsage.kind(of: meter("Whatever", used: 1, hours: 168)) == .week)
        #expect(AgentsUsage.kind(of: meter("Whatever", used: 1, hours: 720)) == .month)
        #expect(AgentsUsage.kind(of: meter("Extra", used: 1, hours: 24)) == nil, "a day is none of the three")
        #expect(AgentsUsage.kind(of: meter("Weekly limit", used: 1, hours: nil)) == .week)
        #expect(AgentsUsage.kind(of: meter("Session", used: 1, hours: nil)) == .fiveHour)
        #expect(AgentsUsage.kind(of: meter("Credits", used: 1, hours: nil)) == nil)
    }

    @Test func theRowsAreWhatIsLeftWithATickWhereEvenUseWouldBe() {
        let rows = AgentsUsage.rows(
            from: [
                meter("Weekly", used: 58, hours: 168, resetsIn: 4 * 86_400 + 8 * 3600),
                meter("Session", used: 27, hours: 5, resetsIn: 3 * 3600 + 12 * 60),
                meter("Sonnet only", used: 90, hours: 168, resetsIn: 3600),
                meter("Credits", used: 5, hours: nil),
            ], now: now)
        #expect(rows.map(\.kind) == [.fiveHour, .week], "in order, the first of each kind, others left out")
        #expect(abs(rows[0].left - 0.73) < 1e-9 && rows[0].reset == "3h 12m")
        #expect(abs(rows[0].pace! - (3.2 / 5)) < 1e-9, "the share of the window still to run")
        #expect(abs(rows[1].left - 0.42) < 1e-9 && rows[1].reset == "4d 8h")
        let over = AgentsUsage.rows(from: [meter("Weekly", used: 130, hours: 168)], now: now)
        #expect(over[0].left == 0 && over[0].pace == nil && over[0].reset == nil)
        #expect(AgentsUsage.resetText(42 * 60) == "42m" && AgentsUsage.resetText(3600) == "1h 0m")
        #expect(QuotaRow.Kind.allLabels == ["5h", "W", "M"])
    }

    @Test func aToolThatCannotBeReadShowsAShortStateAndNotZeros() {
        let withRows = ProviderSnapshot(
            providerID: "claude", displayName: "Claude",
            lines: [
                .progress(
                    label: "Session", used: 27, limit: 100, format: .percent, resetsAt: now.addingTimeInterval(600),
                    periodDurationMs: 5 * 3_600_000)
            ])
        let blocks = AgentsUsage.blocks(
            providers: ["claude", "codex", "grok", "cline", "cursor"].map(provider),
            snapshots: [
                "claude": withRows, "cline": ProviderSnapshot(providerID: "cline", displayName: "Cline", lines: []),
            ],
            errors: ["codex": "Sign in again", "grok": "It didn't answer within 120 seconds."],
            categories: ["codex": .authExpired], now: now)
        #expect(blocks.map(\.id) == ["claude", "codex", "grok", "cursor"], "Cline has spend only: no block")
        #expect(blocks[1].state == .signIn && blocks[1].detail == "Sign in again")
        #expect(blocks[2].state == .unavailable)
        #expect(blocks[3].state == .checking && blocks[3].detail == nil)
        if case .rows(let rows) = blocks[0].state { #expect(rows.count == 1) } else { Issue.record("rows expected") }
        // An error over numbers that were read keeps them.
        let stale = AgentsUsage.blocks(
            providers: [provider("claude")], snapshots: ["claude": withRows], errors: ["claude": "Offline"],
            categories: [:], now: now)
        if case .rows = stale[0].state { #expect(stale[0].detail == "Offline") } else { Issue.record("rows expected") }
    }
}

extension QuotaRow.Kind {
    static var allLabels: [String] { [QuotaRow.Kind.fiveHour, .week, .month].map(\.label) }
}
