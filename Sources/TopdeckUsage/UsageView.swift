// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckCore
import TopdeckFeatures
import TopdeckSurface

/// The Agents space's usage column: a donut of what each tool cost in the period with a row for each, and under
/// a hairline each tool's quota rows in two columns; or, before any tool is on, the ones to turn on.
struct UsageColumn: View {
    let usage: UsageFeature

    var body: some View {
        // Times to a reset ("3h 12m") move on once a minute, only while the screen is on.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if usage.enabledProviders.isEmpty {
                UsageOnboarding(usage: usage)
            } else {
                content(now: context.date)
            }
        }
        // The same local check onboarding runs, so the menu knows which tools are signed in.
        .task { if !usage.hasDetected { await usage.detect() } }
    }

    private func content(now: Date) -> some View {
        let tools = usage.toolUsage(now: now)
        let blocks = usage.quotaBlocks(now: now)
        return VStack(spacing: 9) {
            if !tools.isEmpty {
                SpendRow(tools: tools)
            } else {
                DeckEmptyLine(usage.refreshing.isEmpty ? "No usage" : "Checking…").frame(height: 60)
            }
            if !blocks.isEmpty {
                DeckSeparator()
                ScrollView { QuotaGrid(blocks: blocks) }.fadingEdges(length: 6, atStart: false)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: Spend

/// The donut with its total in the middle, and a row for each tool: its colour, its name, its tokens, its cost.
private struct SpendRow: View {
    let tools: [ToolUsage]

    var body: some View {
        let shares = AgentsUsage.shares(tools)
        let dollars = tools.reduce(0) { $0 + ($1.cost ?? 0) }
        let center =
            dollars > 0
            ? AgentsFormat.donutCost(dollars) : AgentsFormat.tokens(tools.reduce(0) { $0 + $1.tokens })
        HStack(spacing: 14) {
            Donut(shares: shares, center: center)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(tools) { tool in
                        HStack(spacing: 7) {
                            Circle().fill(Deck.Provider.color(tool.id)).frame(width: 7, height: 7)
                            Text(tool.name).deckText(.body).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(AgentsFormat.tokens(tool.tokens)).deckText(.caption).frame(
                                width: 48, alignment: .trailing)
                            Text(tool.cost.map(AgentsFormat.cost) ?? "–")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .frame(width: 62, alignment: .trailing)
                        }
                        .frame(height: 19)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(tool.name), \(AgentsFormat.tokens(tool.tokens)) tokens, \(tool.cost.map(AgentsFormat.cost) ?? "no cost")"
                        )
                    }
                }
            }
            .frame(height: 84)
            .scrollIndicators(.never)
        }
        .frame(height: 84)
    }
}

/// A ring of one arc for each tool, in the tool's colour, with the total at its centre.
struct Donut: View {
    let shares: [(id: String, fraction: Double)]
    let center: String

    var body: some View {
        ZStack {
            ForEach(arcs, id: \.id) { arc in
                Circle()
                    .trim(from: arc.from, to: arc.to)
                    .stroke(Deck.Provider.color(arc.id), style: StrokeStyle(lineWidth: 11, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 60, height: 60)
            Text(center).font(.system(size: 13, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7).frame(width: 52)
        }
        .frame(width: 84, height: 84)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spend by tool")
        .accessibilityValue(center)
    }

    /// Each arc's start and end as a share of the circle, with a hair of space between them when there are
    /// several.
    private var arcs: [(id: String, from: Double, to: Double)] {
        let gap = shares.count > 1 ? 1.5 / (2 * .pi * 30) : 0
        var start = 0.0
        return shares.map { share in
            defer { start += share.fraction }
            return (share.id, start + gap / 2, max(start + share.fraction - gap / 2, start + gap / 2 + 0.001))
        }
    }
}

// MARK: Quota

/// The tools' quota blocks, two to a row.
private struct QuotaGrid: View {
    let blocks: [QuotaBlock]

    var body: some View {
        let rows = stride(from: 0, to: blocks.count, by: 2).map { Array(blocks[$0..<min($0 + 2, blocks.count)]) }
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, pair in
                GridRow {
                    ForEach(pair) { QuotaBlockView(block: $0) }
                    if pair.count == 1 { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct QuotaBlockView: View {
    let block: QuotaBlock

    var body: some View {
        let color = Deck.Provider.color(block.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(block.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(color).lineLimit(1)
            }
            .frame(height: 19)
            switch block.state {
            case .rows(let rows):
                ForEach(rows) { QuotaRowView(row: $0, color: color, provider: block.name) }
            case .checking:
                state("Checking…")
            case .signIn:
                state("Sign in")
            case .unavailable:
                state("Unavailable")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .help(block.detail ?? "")
    }

    private func state(_ text: String) -> some View {
        Text(text).deckText(.caption).lineLimit(1).frame(height: 19, alignment: .leading)
    }
}

/// One window: its label, a bar in the tool's colour for what is left with a tick where even use would have
/// it by now, the percent left and the time to the reset.
private struct QuotaRowView: View {
    let row: QuotaRow
    let color: Color
    let provider: String

    var body: some View {
        HStack(spacing: 6) {
            Text(row.kind.label).deckText(.caption).frame(width: 18, alignment: .leading)
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
            Text("\(Int((row.left * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .frame(width: 40, alignment: .trailing)
            Text(row.reset ?? "").font(.system(size: 11).monospacedDigit()).foregroundStyle(Deck.tertiary)
                .lineLimit(1).fixedSize().frame(width: 46, alignment: .trailing)
        }
        .frame(height: 19)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider), \(Self.window(row.kind))")
        .accessibilityValue(
            "\(Int((row.left * 100).rounded())) percent left" + (row.reset.map { ", resets in \($0)" } ?? ""))
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
private struct UsageOnboarding: View {
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
