// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckCore
import TopdeckFeatures
import TopdeckSurface

/// The Usage tab: the provider picked in the second row, as its headline limit, the others beside it,
/// and what it cost; or, before any provider is on, the ones to turn on.
struct UsageView: View {
    let usage: UsageFeature

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Relative times ("Resets in 2h 13m") move on once a minute, only while the tab is on screen.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Group {
                if let provider = usage.currentProvider {
                    ProviderPage(usage: usage, provider: provider, now: context.date)
                } else {
                    UsageOnboarding(usage: usage)
                }
            }
            .id(usage.currentProvider?.id)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: usage.currentProvider?.id)
        }
        // The same local check onboarding runs, so the menu knows which tools are signed in.
        .task { if !usage.hasDetected { await usage.detect() } }
    }
}

/// The second row's part of the tab: a chip for each provider that's on, a menu to turn another on,
/// refresh, and the provider's own usage page.
struct UsageActions: View {
    let usage: UsageFeature

    var body: some View {
        let providers = usage.enabledProviders
        HStack(spacing: 6) {
            // Up to three chips fit the smallest deck; more scroll sideways.
            if providers.count > 3 {
                ScrollView(.horizontal) { chips(providers) }
                    .scrollIndicators(.hidden)
                    .frame(width: 220)
            } else {
                chips(providers)
            }
            AddProviderMenu(usage: usage)
            RefreshButton(spinning: !usage.refreshing.isEmpty) { Task { await usage.refreshAll(force: true) } }
            if let provider = usage.currentProvider, let dashboard = provider.dashboard {
                DeckIconButton(.arrowUpRight, label: "Open \(provider.name)'s usage page") {
                    NSWorkspace.shared.open(dashboard)
                }
            }
        }
        .padding(.trailing, 4)
    }

    private func chips(_ providers: [UsageProvider]) -> some View {
        HStack(spacing: 6) {
            ForEach(providers) { provider in
                let selected = provider.id == usage.currentProvider?.id
                Button(provider.name) { usage.selectedProvider = provider.id }
                    .buttonStyle(ProviderChipStyle(selected: selected))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .contextMenu { Button("Turn Off \(provider.name)") { usage.setEnabled(provider.id, false) } }
            }
        }
    }
}

/// A provider's name in the second row: white when picked, an outline otherwise.
private struct ProviderChipStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Deck.Radius.control, style: .continuous)
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(selected ? Deck.onFill : Deck.secondary)
            .lineLimit(1)
            .padding(.horizontal, 13)
            .frame(height: Deck.Metric.navHeight)
            .background(shape.fill(selected ? Deck.text : .clear))
            .overlay { if !selected { shape.strokeBorder(Deck.hairline, lineWidth: 1) } }
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.75 : 1)
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

/// One provider: its headline limit big on the left, the other limits in the middle, spend and the
/// daily trend on the right. Each shows only when the provider reports it.
private struct ProviderPage: View {
    let usage: UsageFeature
    let provider: UsageProvider
    let now: Date

    var body: some View {
        let snapshot = usage.snapshots[provider.id]
        let meters = snapshot?.meters ?? []
        let spend = snapshot.flatMap(SpendCard.init)
        let notice = usage.errors[provider.id] ?? snapshot?.warning
        if meters.isEmpty, spend == nil {
            DeckEmptyLine(
                notice
                    ?? (usage.refreshing.contains(provider.id) || snapshot == nil ? "Checking…" : "No limits to show"))
        } else {
            VStack(spacing: 8) {
                if let notice {
                    Text(notice)
                        .deckText(.detail, color: Deck.signal)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }
                cards(meters: meters, spend: spend)
            }
        }
    }

    private func cards(meters: [Meter], spend: SpendCard?) -> some View {
        let rest = Array(meters.dropFirst())
        var weights: [CGFloat] = []
        if !meters.isEmpty { weights.append(1) }
        if !rest.isEmpty { weights.append(1) }
        if spend != nil { weights.append(1.2) }
        return DeckWeightedRow(weights) {
            if let headline = meters.first { HeadlineCard(meter: headline, now: now) }
            if !rest.isEmpty { LimitsColumn(meters: rest) }
            if let spend { spend }
        }
    }
}

/// The headline limit: its name, the number, its bar, and when it resets and whether it will last.
private struct HeadlineCard: View {
    let meter: Meter
    let now: Date

    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meter.label).deckText(.caption).lineLimit(1)
                    Text(meter.headline).deckText(.timer).lineLimit(1).minimumScaleFactor(0.5)
                }
                Spacer(minLength: Deck.Metric.gap)
                VStack(alignment: .leading, spacing: 6) {
                    DeckBar(meter.fraction, tone: meter.tone)
                    ViewThatFits(in: .horizontal) {
                        footer(paceWords: true)
                        footer(paceWords: false)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .combine)
    }

    private func footer(paceWords: Bool) -> some View {
        HStack(spacing: 6) {
            if let reset = meter.resetLabel(now: now) { Text(reset).deckText(.detail).lineLimit(1) }
            Spacer(minLength: 0)
            PaceBadge(meter: meter, now: now, showsWords: paceWords)
        }
    }
}

/// The other limits, a card each sharing the height; past three they keep their size and scroll.
private struct LimitsColumn: View {
    let meters: [Meter]

    var body: some View {
        if meters.count <= 3 {
            VStack(spacing: Deck.Metric.gap) {
                ForEach(meters) { LimitCard(meter: $0).frame(maxHeight: .infinity) }
            }
        } else {
            ScrollView {
                VStack(spacing: Deck.Metric.gap) {
                    ForEach(meters) { LimitCard(meter: $0).frame(height: 64) }
                }
            }
            .fadingEdges(length: 6)
        }
    }
}

private struct LimitCard: View {
    let meter: Meter

    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 6) {
                // The amount in full when the name leaves room for it, else just the number.
                ViewThatFits(in: .horizontal) {
                    row(meter.detail)
                    row(meter.headline)
                }
                DeckBar(meter.fraction, tone: meter.tone)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(meter.label), \(meter.detail)")
    }

    private func row(_ amount: String) -> some View {
        HStack(spacing: 6) {
            Text(meter.label).deckText(.body).lineLimit(1).fixedSize()
            Spacer(minLength: 0)
            Text(amount).deckText(.detail).lineLimit(1).fixedSize()
        }
    }
}

/// What the provider cost over the last 30 days, today and yesterday, the daily trend, and the notes it
/// adds, like an organization's status.
private struct SpendCard: View {
    let snapshot: ProviderSnapshot

    private let month: String?
    private let recent: String?
    private let trend: [MetricChartPoint]

    init?(_ snapshot: ProviderSnapshot) {
        self.snapshot = snapshot
        month = snapshot.values(for: "Last 30 Days")?.first.map { MetricFormatter.string(for: $0, style: .row) }
        let days = ["Today", "Yesterday"].compactMap { label in
            snapshot.values(for: label)?.first.map { "\(label) \(MetricFormatter.string(for: $0, style: .row))" }
        }
        recent = days.isEmpty ? nil : days.joined(separator: " · ")
        trend = Array((snapshot.trend ?? []).suffix(30))
        if month == nil, recent == nil, trend.count < 2, snapshot.notes.isEmpty { return nil }
    }

    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: Deck.Metric.gap) {
                if month != nil || recent != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        if let month {
                            Text("Last 30 days").deckText(.caption)
                            Text(month).deckText(.metric).lineLimit(1).minimumScaleFactor(0.5)
                        }
                        if let recent { Text(recent).deckText(.detail).lineLimit(1).minimumScaleFactor(0.8) }
                    }
                }
                if !snapshot.notes.isEmpty {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(Array(snapshot.notes.enumerated()), id: \.offset) { _, note in
                                HStack(spacing: 6) {
                                    Text(note.label).deckText(.caption).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(note.value).deckText(.detail).lineLimit(1)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 64)
                }
                if trend.count > 1 {
                    Spacer(minLength: 0)
                    DailyBars(points: trend)
                        .frame(maxHeight: 64)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// The daily trend as bars, today's in white.
private struct DailyBars: View {
    let points: [MetricChartPoint]

    var body: some View {
        let peak = max(points.map(\.value).max() ?? 1, 1)
        GeometryReader { space in
            HStack(alignment: .bottom, spacing: points.count > 16 ? 2 : 5) {
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                        .fill(index == points.count - 1 ? Deck.text : Deck.control)
                        .frame(height: max(3, space.size.height * point.value / peak))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(minHeight: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily usage chart")
        .accessibilityValue(points.max(by: { $0.value < $1.value }).map { "Peak \($0.readout)" } ?? "")
    }
}

/// Before any provider is on: the tools to turn on, the ones signed in on this Mac first.
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

extension UsageFeature {
    /// Usage's part of the second row: the provider chips, add, refresh and its usage page.
    public var actions: some View { UsageActions(usage: self) }
}

extension ProviderSnapshot {
    /// The badges and notes a provider adds beside its limits: label and text.
    var notes: [(label: String, value: String)] {
        lines.compactMap { line -> (label: String, value: String)? in
            switch line {
            case .badge(let label, let text, _, _) where !line.isError: (label, text)
            case .text(let label, let value, _, _): (label, value)
            case .values(let label, let values, _, _, _, _) where !Self.spendPeriods.contains(label):
                (label, values.map { MetricFormatter.string(for: $0, style: .row) }.joined(separator: " · "))
            default: nil
            }
        }
    }

    static let spendPeriods = ["Today", "Yesterday", "Last 30 Days"]

    /// A spend row's values, like Today's dollars and tokens.
    func values(for label: String) -> [MetricValue]? {
        for line in lines {
            if case .values(label, let values, _, _, _, _) = line, !values.isEmpty { return values }
        }
        return nil
    }

    func dollars(for label: String) -> Double? {
        values(for: label)?.first { $0.kind == .dollars }?.number
    }

    /// The daily usage trend, when the provider keeps local history.
    var trend: [MetricChartPoint]? {
        for line in lines {
            if case .chart(_, let points, _) = line { return points }
        }
        return nil
    }
}
