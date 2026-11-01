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

    @Test func costsHaveCentsInRowsAndNoneInTheLargeFigure() {
        #expect(AgentsFormat.cost(241.6) == "$241.60" && AgentsFormat.cost(8.75) == "$8.75")
        #expect(AgentsFormat.cost(1234.5) == "$1,234.50")
        #expect(AgentsFormat.wholeCost(4178.24) == "$4,178" && AgentsFormat.wholeCost(4178.6) == "$4,179")
        #expect(AgentsFormat.wholeCost(0.4) == "$0" && AgentsFormat.wholeCost(1_234_567) == "$1,234,567")
    }

    @Test func aSessionsAgeIsNowThenMinutesHoursAndDays() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        func text(_ seconds: TimeInterval) -> String {
            AgentsFormat.elapsed(since: now.addingTimeInterval(-seconds), now: now)
        }
        #expect(text(0) == "now" && text(59) == "now" && text(-30) == "now", "a clock that runs ahead is still now")
        #expect(text(60) == "1m" && text(119) == "1m" && text(59 * 60 + 59) == "59m")
        #expect(text(3600) == "1h" && text(23 * 3600 + 3599) == "23h")
        #expect(text(86_400) == "1d" && text(3 * 86_400 + 5000) == "3d")
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

    @Test func theShareBarSlicesByCostElseByTokens() {
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
        let rows = AgentsUsage.pools(
            from: [
                meter("Weekly", used: 58, hours: 168, resetsIn: 4 * 86_400 + 8 * 3600),
                meter("Session", used: 27, hours: 5, resetsIn: 3 * 3600 + 12 * 60),
                meter("Sonnet only", used: 90, hours: 168, resetsIn: 3600),
                meter("Credits", used: 5, hours: nil),
            ], now: now)[0].rows
        #expect(rows.map(\.kind) == [.fiveHour, .week], "in order, the first of each kind, others left out")
        #expect(abs(rows[0].left - 0.73) < 1e-9 && rows[0].reset == "3h 12m")
        #expect(abs(rows[0].pace! - (3.2 / 5)) < 1e-9, "the share of the window still to run")
        #expect(abs(rows[1].left - 0.42) < 1e-9 && rows[1].reset == "4d 8h")
        let over = AgentsUsage.pools(from: [meter("Weekly", used: 130, hours: 168)], now: now)[0].rows
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
        if case .rows(let pools) = blocks[0].state {
            #expect(pools.count == 1 && pools[0].rows.count == 1)
        } else {
            Issue.record("rows expected")
        }
        // An error over numbers that were read keeps them.
        let stale = AgentsUsage.blocks(
            providers: [provider("claude")], snapshots: ["claude": withRows], errors: ["claude": "Offline"],
            categories: [:], now: now)
        if case .rows = stale[0].state { #expect(stale[0].detail == "Offline") } else { Issue.record("rows expected") }
    }
}

extension AgentsUsageTests {
    @Test func theColumnsNarrowBelowNowsBreakpoint() {
        #expect(AgentsUsage.columns(width: 659).left == 150 && AgentsUsage.columns(width: 659).middle == 192)
        #expect(AgentsUsage.columns(width: 660).left == 176 && AgentsUsage.columns(width: 660).middle == 214)
    }

    @Test func aRowIsAsTallAsItsQuotaNeedsAndTwoLinesAtLeast() {
        #expect(AgentsUsage.rowHeight(lines: 0) == 43 && AgentsUsage.rowHeight(lines: 1) == 43)
        #expect(AgentsUsage.rowHeight(lines: 2) == 43 && AgentsUsage.rowHeight(lines: 3) == 60)
    }

    private func block(_ id: String, _ state: QuotaBlock.State) -> QuotaBlock {
        QuotaBlock(id: id, name: id.capitalized, state: state, detail: nil)
    }

    private func quota(_ count: Int) -> QuotaBlock.State {
        .rows([
            QuotaPool(
                name: nil,
                rows: [QuotaRow.Kind.fiveHour, .week, .month].prefix(count).map {
                    QuotaRow(kind: $0, left: 0.5, reset: nil, pace: nil)
                })
        ])
    }

    /// What each tool's pools come to: the main pool's kinds, then "name: kinds" for each other.
    private func shape(_ labels: [(String, Double?)]) -> [String] {
        AgentsUsage.pools(from: labels.map { meter($0.0, used: 10, hours: $0.1) }, now: now).map {
            ($0.name.map { "\($0): " } ?? "") + $0.rows.map(\.kind.label).joined(separator: ",")
        }
    }

    @Test func aPoolIsNamedByItsMetersLabelLessTheWindowWords() {
        let names = [
            "Session", "Weekly", "Monthly", "5-hour", "Weekly limit", "Daily quota", "Weekly quota", "WEEK", "5 hour",
        ]
        for label in names { #expect(AgentsUsage.poolName(of: label) == nil, "\(label)") }
        #expect(AgentsUsage.poolName(of: "Claude") == "Claude" && AgentsUsage.poolName(of: "Claude Weekly") == "Claude")
        #expect(AgentsUsage.poolName(of: "Spark Weekly") == "Spark" && AgentsUsage.poolName(of: "  spark  ") == "spark")
        #expect(AgentsUsage.poolName(of: "Sonnet") == "Sonnet")
    }

    @Test func aToolWithSeveralPoolsShowsAllOfThem() {
        #expect(
            shape([("Session", 5), ("Weekly", 168), ("Claude", 5), ("Claude Weekly", 168)])
                == ["5h,W", "Claude: 5h,W"], "Antigravity")
        #expect(
            shape([("Session", 5), ("Weekly", 168), ("Spark", 5), ("Spark Weekly", 168)]) == ["5h,W", "Spark: 5h,W"],
            "Codex")
        #expect(
            shape([("Spark", 5), ("Spark Weekly", 168), ("Session", 5), ("Weekly", 168)]) == ["5h,W", "Spark: 5h,W"],
            "the main pool is first however the provider orders them")
        #expect(shape([("Claude", 5), ("Claude Weekly", 168)]) == ["5h,W"], "a tool with one pool shows it unnamed")
    }

    @Test func everyOtherProvidersMetersAreOneUnnamedPool() {
        let sets: [String: ([(String, Double?)], [String])] = [
            "claude": ([("Session", 5), ("Weekly", 168), ("Sonnet", 168), ("Fable", 168)], ["5h,W"]),
            "cline": ([("5-hour", 5), ("Weekly", 168), ("Monthly", 720)], ["5h,W,M"]),
            "ollama": ([("Session", 5), ("Weekly", 168), ("Monthly", 720)], ["5h,W,M"]),
            "opencode": ([("Session", 5), ("Weekly", 168), ("Monthly", 720)], ["5h,W,M"]),
            "zai": ([("Session", 5), ("Weekly", 168), ("Web Searches", 720)], ["5h,W,M"]),
            "grok": ([("Weekly limit", 168)], ["W"]),
            "devin": ([("Daily quota", 24), ("Weekly quota", 168)], ["W"]),
            "copilot": ([("Credits", 720), ("Chat", 720), ("Completions", 720)], ["M"]),
            "cursor": (
                [
                    ("Total usage", 720), ("Cursor Models", 720), ("Other Models", 720), ("On-demand", 720),
                    ("Requests", 720), ("Grok Bot usage", 168),
                ], ["W,M"]
            ),
            "openrouter": ([("Credits", nil), ("Key Limit", nil)], []),
        ]
        for (id, set) in sets { #expect(shape(set.0) == set.1, "\(id)") }
    }

    @Test func aRowCountsTheCaptionOfEachNamedPool() {
        func pool(_ name: String?, _ count: Int) -> QuotaPool {
            QuotaPool(
                name: name, rows: (0..<count).map { _ in QuotaRow(kind: .fiveHour, left: 1, reset: nil, pace: nil) })
        }
        let two = QuotaBlock(
            id: "antigravity", name: "Antigravity", state: .rows([pool(nil, 2), pool("Claude", 2)]), detail: nil)
        let row = ToolRow(id: "antigravity", name: "Antigravity", usage: nil, quota: two)
        #expect(row.quotaLines == 5 && row.height == 94, "9 + 17 for each of four rows and one caption")
    }

    @Test func theTableListsTheToolsWithUsageThenTheOnesWithOnlyAQuota() {
        let tools = [
            ToolUsage(id: "claude", name: "Claude", tokens: 9, cost: 3),
            ToolUsage(id: "grok", name: "Grok", tokens: 1, cost: nil),
        ]
        let blocks = [
            block("cline", quota(3)), block("grok", .signIn), block("claude", quota(2)), block("codex", .checking),
        ]
        let rows = AgentsUsage.table(tools: tools, blocks: blocks)
        #expect(rows.map(\.id) == ["claude", "grok", "cline", "codex"], "usage order, then quota-only in block order")
        #expect(rows.map(\.quotaLines) == [2, 1, 3, 1])
        #expect(rows.map(\.height) == [43, 43, 60, 43])
        #expect(rows[0].usage?.tokens == 9 && rows[0].quota?.id == "claude")
        #expect(rows[2].usage == nil && rows[2].quota?.id == "cline", "no usage in the period: a row all the same")
        let bare = AgentsUsage.table(tools: [ToolUsage(id: "cline", name: "Cline", tokens: 5, cost: 1)], blocks: [])
        #expect(bare.count == 1 && bare[0].quota == nil && bare[0].quotaLines == 0 && bare[0].height == 43)
        #expect(AgentsUsage.table(tools: [], blocks: []).isEmpty)
    }

    @Test func totalsHaveNoCostWhenNoToolIsPriced() {
        let priced = AgentsUsage.totals([
            ToolUsage(id: "a", name: "A", tokens: 100, cost: 2.5), ToolUsage(id: "b", name: "B", tokens: 50, cost: nil),
        ])
        #expect(priced.cost == 2.5 && priced.tokens == 150)
        let unpriced = AgentsUsage.totals([ToolUsage(id: "b", name: "B", tokens: 50, cost: nil)])
        #expect(unpriced.cost == nil && unpriced.tokens == 50)
        #expect(AgentsUsage.totals([]).cost == nil && AgentsUsage.totals([]).tokens == 0)
    }

    @Test func theDailySeriesSumsTheToolsFillsGapsAndEndsToday() {
        let snapshots = [
            "claude": snapshot("claude", [(0, 100, 1), (2, 200, 2), (60, 999, 9)]),
            "codex": snapshot("codex", [(0, 50, 0.5), (2, 1, nil), (-1, 77, 7)]),
            "off": snapshot("off", [(0, 1000, 10)]),
        ]
        let days = AgentsUsage.daily(
            snapshots: snapshots, providers: ["claude", "codex", "absent"].map(provider), now: now,
            calendar: Self.calendar)
        #expect(days.count == 30)
        #expect(days.last?.date == Self.calendar.startOfDay(for: now), "today is the last bar")
        #expect(
            days.first?.date == Self.calendar.date(byAdding: .day, value: -29, to: Self.calendar.startOfDay(for: now)))
        #expect(days[29].tokens == 150 && days[29].cost == 1.5, "summed across the tools")
        #expect(days[27].tokens == 201 && days[27].cost == 2, "an unpriced day adds tokens only")
        #expect(days[28].tokens == 0 && days[28].cost == 0, "a day with none is zero")
        #expect(days.map(\.tokens).reduce(0, +) == 351, "outside the 30 days, in the future and off tools are left out")
    }

    @Test func aPeriodSpansItsDaysAndAllRunsFromTheFirstDayWithUsage() {
        let snapshots = [
            "claude": snapshot("claude", [(0, 100, 1), (10, 0, 0), (40, 5, 1)]),
            "codex": snapshot("codex", [(-3, 9, 9)]),
        ]
        let providers = ["claude", "codex"].map(provider)
        func days(_ period: UsagePeriod, _ snapshots: [String: ProviderSnapshot] = snapshots) -> Int {
            AgentsUsage.days(in: period, snapshots: snapshots, providers: providers, now: now, calendar: Self.calendar)
        }
        #expect([UsagePeriod.today, .week, .month].map { days($0) } == [1, 7, 30])
        #expect(days(.all) == 41, "from 40 days back through today, a future day and an empty one not counting")
        #expect(days(.all, ["claude": snapshot("claude", [(0, 3, nil)])]) == 1)
        #expect(days(.all, [:]) == 1, "no usage at all: one day, never zero")
    }
}

extension QuotaRow.Kind {
    static var allLabels: [String] { [QuotaRow.Kind.fiveHour, .week, .month].map(\.label) }
}
