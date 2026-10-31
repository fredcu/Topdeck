// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckFeatures
import TopdeckSurface

/// The Agents space's body, as the board: on the left (206 wide) the agents that need you and the ones at work;
/// on the right what the tools cost and how much of their quotas is left. With nothing waiting or running the left
/// column and its hairline are gone and the usage fills the width. A part is left out when its feature is off.
public struct AgentsScreen: View {
    let agents: AgentsFeature?
    let usage: UsageFeature?

    public init(agents: AgentsFeature?, usage: UsageFeature?) {
        self.agents = agents
        self.usage = usage
    }

    public var body: some View {
        HStack(spacing: Deck.Metric.gap) {
            if let agents, agents.hasActivity {
                AgentsColumn(agents: agents).frame(width: 206)
                Rectangle().fill(Deck.hairline).frame(width: 1)
            }
            if let usage { UsageColumn(usage: usage) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The second row's title: how many agents wait for you, or "Agents" when none does.
public struct AgentsTitle: View {
    let agents: AgentsFeature?

    public init(agents: AgentsFeature?) { self.agents = agents }

    public var body: some View {
        let waiting = agents?.waitingCount ?? 0
        Text(waiting > 0 ? "\(waiting) waiting" : "Agents").deckText(.title).lineLimit(1)
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
