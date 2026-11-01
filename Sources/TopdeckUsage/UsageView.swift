// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckCore
import TopdeckFeatures
import TopdeckSurface

// MARK: Summary

/// The period at a glance, for the left column when no session is listed: the total and its tokens, each tool's
/// share, the last 30 days' spend with today in the accent, and today against the daily average.
struct UsageSummary: View {
    let tools: [ToolUsage]
    /// The last 30 days, oldest first, whatever the period.
    let days: [DaySpend]
    /// The days the period spans, for the average.
    let periodDays: Int
    @Environment(\.deckAccent) private var accent

    var body: some View {
        let totals = AgentsUsage.totals(tools)
        let byCost = totals.cost != nil
        let average = (totals.cost ?? Double(totals.tokens)) / Double(max(periodDays, 1))
        VStack(alignment: .leading, spacing: 0) {
            Text(totals.cost.map(AgentsFormat.wholeCost) ?? AgentsFormat.tokens(totals.tokens))
                .deckText(.metric).lineLimit(1).minimumScaleFactor(0.7)
            if byCost {
                Text("\(AgentsFormat.tokens(totals.tokens)) tokens").deckText(.caption).lineLimit(1).padding(.top, 4)
            }
            ShareBar(shares: AgentsUsage.shares(tools)).padding(.top, 12)
            DayBars(days: days, accent: accent).padding(.top, 18)
            HStack(alignment: .top) {
                figure("Today", amount(cost: days.last?.cost ?? 0, tokens: days.last?.tokens ?? 0, byCost), .leading)
                Spacer(minLength: 4)
                figure("Per day", amount(cost: average, tokens: Int(average), byCost), .trailing)
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func amount(cost: Double, tokens: Int, _ byCost: Bool) -> String {
        byCost ? AgentsFormat.cost(cost) : AgentsFormat.tokens(tokens)
    }

    private func figure(_ label: String, _ value: String, _ alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(label).font(.system(size: 11)).foregroundStyle(Deck.tertiary)
            Text(value).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Deck.text)
        }
        .lineLimit(1)
    }
}

/// Each tool's share of the total as a 5 point bar in the tool's colour, with a hair between segments.
private struct ShareBar: View {
    let shares: [(id: String, fraction: Double)]
    private static let gap: CGFloat = 1.5

    var body: some View {
        GeometryReader { space in
            let room = max(space.size.width - Self.gap * CGFloat(max(shares.count - 1, 0)), 0)
            HStack(spacing: Self.gap) {
                ForEach(shares, id: \.id) { share in
                    Rectangle().fill(Deck.Provider.color(share.id)).frame(width: room * share.fraction)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

/// The last 30 days as bars, today's in the accent. By cost, or by tokens when no day has a price.
private struct DayBars: View {
    let days: [DaySpend]
    let accent: Color
    private static let height: CGFloat = 52

    var body: some View {
        let byCost = days.contains { $0.cost > 0 }
        let values = days.map { byCost ? $0.cost : Double($0.tokens) }
        let top = values.max() ?? 0
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(days.indices, id: \.self) { index in
                let amount =
                    byCost ? AgentsFormat.cost(days[index].cost) : "\(AgentsFormat.tokens(days[index].tokens)) tokens"
                let date = days[index].date.formatted(.dateTime.month(.abbreviated).day())
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index == days.count - 1 ? accent : Deck.control)
                    .frame(height: top > 0 ? max(2, Self.height * values[index] / top) : 2)
                    .frame(maxWidth: .infinity)
                    .help("\(date): \(amount)")
                    .accessibilityElement()
                    .accessibilityLabel(date)
                    .accessibilityValue(amount)
            }
        }
        .frame(height: Self.height, alignment: .bottom)
    }
}

// MARK: Table

/// Spend and quota as one table: a row for each tool, level across the two columns and split by hairlines. It
/// scrolls as one, so the columns never part.
struct UsageTable: View {
    let rows: [ToolRow]
    let middle: CGFloat

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: Deck.Metric.columnGap) {
                column { SpendCell(row: $0) }.frame(width: middle)
                Color.clear.frame(width: 1)
                column { QuotaCell(row: $0) }.frame(maxWidth: .infinity)
            }
        }
        .fadingEdges(length: 6, atStart: false)
        // The hairline between the columns runs the body's full height, not just the rows'.
        .background(alignment: .leading) { DeckRule().padding(.leading, middle + Deck.Metric.columnGap) }
    }

    private func column<Cell: View>(@ViewBuilder _ cell: @escaping (ToolRow) -> Cell) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                cell(row)
                    .frame(height: row.height)
                    .overlay(alignment: .top) { if index > 0 { DeckSeparator() } }
            }
        }
    }
}

/// A tool's colour and name with its cost, and under them its tokens.
private struct SpendCell: View {
    let row: ToolRow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Circle().fill(Deck.Provider.color(row.id)).frame(width: 7, height: 7)
                Text(row.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Deck.text).lineLimit(1)
                Spacer(minLength: 4)
                if let usage = row.usage {
                    Text(usage.cost.map(AgentsFormat.cost) ?? "–")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Deck.text)
                        .lineLimit(1)
                }
            }
            .frame(height: 16)
            if let usage = row.usage {
                Text("\(AgentsFormat.tokens(usage.tokens)) tokens").deckText(.caption).lineLimit(1)
                    .padding(.leading, 13).frame(height: 16, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            row.usage.map {
                "\(row.name), \(AgentsFormat.tokens($0.tokens)) tokens, \($0.cost.map(AgentsFormat.cost) ?? "no cost")"
            } ?? row.name)
    }
}

/// A tool's quota rows, or the short state in their place.
private struct QuotaCell: View {
    let row: ToolRow

    var body: some View {
        if let block = row.quota {
            VStack(spacing: 1) {
                switch block.state {
                case .rows(let rows):
                    ForEach(rows) { QuotaRowView(row: $0, color: Deck.Provider.color(block.id), provider: block.name) }
                case .checking:
                    state("Checking…")
                case .signIn:
                    state("Sign in")
                case .unavailable:
                    state("Unavailable")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .help(block.detail ?? "")
        } else {
            Color.clear
        }
    }

    private func state(_ text: String) -> some View {
        Text(text).deckText(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).frame(height: 16)
    }
}

/// One window: its label, a bar in the tool's colour for what is left with a tick where even use would have
/// it by now, the percent left and the time to the reset.
private struct QuotaRowView: View {
    let row: QuotaRow
    let color: Color
    let provider: String

    var body: some View {
        let percent = Int((row.left * 100).rounded())
        HStack(spacing: 6) {
            Text(row.kind.label).font(.system(size: 11)).foregroundStyle(Deck.tertiary)
                .frame(width: 16, alignment: .leading)
            GeometryReader { space in
                ZStack(alignment: .leading) {
                    Capsule().fill(Deck.control)
                    Capsule().fill(color).frame(width: space.size.width * row.left)
                    if let pace = row.pace {
                        Rectangle().fill(Deck.text).frame(width: 1.5, height: 9)
                            .offset(x: min(max(space.size.width * pace - 0.75, 0), space.size.width - 1.5))
                    }
                }
                .frame(height: 5)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 9)
            Text("\(percent)%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(percent == 0 ? Deck.stop : Deck.text)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 34, alignment: .trailing)
            Text(row.reset ?? "").font(.system(size: 11).monospacedDigit()).foregroundStyle(Deck.tertiary)
                .lineLimit(1).fixedSize().frame(width: 44, alignment: .trailing)
        }
        .frame(height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider), \(Self.window(row.kind))")
        .accessibilityValue("\(percent) percent left" + (row.reset.map { ", resets in \($0)" } ?? ""))
    }

    private static func window(_ kind: QuotaRow.Kind) -> String {
        switch kind {
        case .fiveHour: "5 hours"
        case .week: "week"
        case .month: "month"
        }
    }
}

// MARK: Before any tool is on

/// The tools to turn on, the ones signed in on this Mac first.
struct UsageOnboarding: View {
    let usage: UsageFeature

    var body: some View {
        let off = usage.providers.filter { !usage.isEnabled($0.id) }
        let ordered = off.filter { usage.detected.contains($0.id) } + off.filter { !usage.detected.contains($0.id) }
        ScrollView {
            VStack(spacing: Deck.Metric.gap) {
                Text("Add the tools you use").deckText(.body, color: Deck.tertiary)
                DeckFlow(spacing: 6) {
                    ForEach(ordered) { provider in
                        let signedIn = usage.detected.contains(provider.id)
                        let needsKey = usage.takesAPIKey(provider.id) && !signedIn
                        Button {
                            usage.add(provider.id)
                        } label: {
                            HStack(spacing: 6) {
                                Text(provider.name)
                                if needsKey { Image(systemName: "key.fill").imageScale(.small) }
                            }
                        }
                        .buttonStyle(.deck(signedIn ? .standard : .outline))
                        .help(
                            needsKey
                                ? "Add an API key for \(provider.name) in Settings"
                                : signedIn
                                    ? "Add \(provider.name)"
                                    : "Add \(provider.name). It isn't signed in on this Mac yet.")
                    }
                }
                .frame(maxWidth: 480)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        }
        .fadingEdges()
    }
}
