// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckFeatures
import TopdeckSurface

/// The Agents space's body, as the board: three columns like Now's. Left, the agents that need you and the ones
/// at work, or with none the period at a glance. Middle and right are one table, a row for each tool: what it
/// cost, and how much of its quota is left. A part is left out when its feature is off.
public struct AgentsScreen: View {
    let agents: AgentsFeature?
    let usage: UsageFeature?

    public init(agents: AgentsFeature?, usage: UsageFeature?) {
        self.agents = agents
        self.usage = usage
    }

    public var body: some View {
        // Times to a reset ("3h 12m") and since a session moved ("2m") move on once a minute, only while the
        // screen is on.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            // Now's columns sit 18 in from the deck's sides; Agents is given 14, so it takes the other 4 itself.
            GeometryReader { proxy in
                columns(now: context.date, width: proxy.size.width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, Deck.Metric.inset - Deck.Metric.side)
        }
        // The same local check onboarding runs, so the menu knows which tools are signed in.
        .task { if let usage, !usage.hasDetected { await usage.detect() } }
    }

    @ViewBuilder private func columns(now: Date, width: CGFloat) -> some View {
        let widths = AgentsUsage.columns(width: width)
        let sessions = agents.flatMap { $0.hasActivity ? $0 : nil }
        if let usage {
            HStack(alignment: .top, spacing: Deck.Metric.columnGap) {
                if usage.enabledProviders.isEmpty {
                    if let sessions {
                        AgentsColumn(agents: sessions, now: now).frame(width: widths.left)
                        DeckRule()
                    }
                    UsageOnboarding(usage: usage)
                } else {
                    usageColumns(usage, sessions: sessions, widths: widths, now: now)
                }
            }
        } else if let sessions {
            AgentsColumn(agents: sessions, now: now)
        }
    }

    @ViewBuilder private func usageColumns(
        _ usage: UsageFeature, sessions: AgentsFeature?, widths: (left: Double, middle: Double), now: Date
    ) -> some View {
        let tools = usage.toolUsage(now: now)
        let rows = AgentsUsage.table(tools: tools, blocks: usage.quotaBlocks(now: now))
        let empty = DeckEmptyLine(usage.refreshing.isEmpty ? "No usage" : "Checking…")
        if sessions == nil && tools.isEmpty && rows.isEmpty {
            empty
        } else {
            Group {
                if let sessions {
                    AgentsColumn(agents: sessions, now: now)
                } else if tools.isEmpty {
                    empty
                } else {
                    UsageSummary(tools: tools, days: usage.dailySpend(now: now), periodDays: usage.periodDays(now: now))
                }
            }
            .frame(width: widths.left)
            DeckRule()
            if rows.isEmpty {
                empty
            } else {
                UsageTable(rows: rows, middle: widths.middle)
            }
        }
    }
}

/// The second row's left side: how many agents wait for you, nothing when none does (the navigation names the
/// space). With sessions listed the period's total sits beside it, since the left column no longer shows it.
public struct AgentsTitle: View {
    let agents: AgentsFeature?
    let usage: UsageFeature?

    public init(agents: AgentsFeature?, usage: UsageFeature?) {
        self.agents = agents
        self.usage = usage
    }

    public var body: some View {
        let waiting = agents?.waitingCount ?? 0
        let title = Text("\(waiting) waiting").deckText(.title).lineLimit(1)
        if waiting == 0 {
            EmptyView()
        } else if let usage {
            let totals = AgentsUsage.totals(usage.toolUsage())
            // The tokens go first, then the cost, when the row is short of room.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    title
                    cost(totals.cost)
                    tokens(totals.tokens)
                }
                HStack(spacing: 12) {
                    title
                    cost(totals.cost)
                }
                title
            }
        } else {
            title
        }
    }

    @ViewBuilder private func cost(_ dollars: Double?) -> some View {
        if let dollars {
            Text(AgentsFormat.cost(dollars)).font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Deck.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private func tokens(_ count: Int) -> some View {
        if count > 0 { Text(AgentsFormat.tokens(count)).deckText(.caption).lineLimit(1) }
    }
}

extension UsageFeature {
    /// The second row's part of the space: the period, refresh, and a menu to add another tool.
    public var actions: some View { UsageActions(usage: self) }
}

private struct UsageActions: View {
    let usage: UsageFeature

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 5) {
                ForEach(UsagePeriod.allCases) { period in
                    PeriodPill(title: period.title, on: usage.period == period) { usage.period = period }
                }
            }
            .padding(.trailing, 6)
            RefreshButton(spinning: !usage.refreshing.isEmpty) { Task { await usage.refreshAll(force: true) } }
            AddProviderMenu(usage: usage)
        }
        // The pills keep their width; the title gives way.
        .fixedSize()
    }
}

/// Today, 7 Days, 30 Days or All: 24 high, tinted in the accent when picked.
private struct PeriodPill: View {
    let title: String
    let on: Bool
    let action: () -> Void
    @Environment(\.deckAccent) private var accent

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? accent : Deck.secondary)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(on ? accent.tint() : Deck.cardRaised))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Every provider that isn't on yet, the ones signed in on this Mac first. One that needs an API key it
/// doesn't have opens Settings for it instead.
private struct AddProviderMenu: View {
    let usage: UsageFeature

    var body: some View {
        let off = usage.providers.filter { !usage.isEnabled($0.id) }
        if !off.isEmpty {
            let ordered = off.filter { usage.detected.contains($0.id) } + off.filter { !usage.detected.contains($0.id) }
            Menu {
                ForEach(ordered) { provider in
                    Button(provider.name) { usage.add(provider.id) }
                }
            } label: {
                DeckIconView(.plus)
                    .foregroundStyle(Deck.secondary)
                    .frame(width: Deck.Metric.iconButton, height: Deck.Metric.iconButton)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a provider")
            .accessibilityLabel("Add a provider")
        }
    }
}
