// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

extension Meter {
    /// Plain until a limit gets close, then amber at 80% and red at 95%.
    var tone: DeckTone? {
        fraction >= 0.95 ? .stop : fraction >= 0.8 ? .signal : nil
    }
}

/// Whether a limit will last until it resets, from OpenUsage's burn-rate projection. Without
/// `showsWords`, just its dot, with the words in the tooltip.
struct PaceBadge: View {
    let meter: Meter
    let now: Date
    var showsWords = true

    var body: some View {
        if let resetsAt = meter.resetsAt, let period = meter.period, let pace = meter.pace(now: now) {
            let (tone, text) = Self.describe(pace.status, meter: meter, resetsAt: resetsAt, period: period, now: now)
            HStack(spacing: 5) {
                DeckDot(tone)
                if showsWords { Text(text).lineLimit(1) }
            }
            .deckText(.detail)
            .help(text)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
        }
    }

    private static func describe(_ status: Pace.Status, meter: Meter, resetsAt: Date, period: TimeInterval, now: Date)
        -> (DeckTone, String)
    {
        switch status {
        case .ahead:
            return (.go, "Plenty left")
        case .onTrack:
            return (.signal, "Cutting it close")
        case .behind:
            let runOut = Pace.secondsToRunOut(
                used: meter.used, limit: meter.limit, resetsAt: resetsAt, periodDuration: period, now: now)
            let label = runOut.flatMap(Formatters.compactDuration).map { "Runs out in \($0)" }
            return (.stop, label ?? "Over pace")
        }
    }
}

/// Refresh, spinning while anything refreshes.
struct RefreshButton: View {
    let spinning: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let spins = spinning && !reduceMotion
        let spin: Animation = spins ? .linear(duration: 1).repeatForever(autoreverses: false) : .default
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .imageScale(.medium)
                .fontWeight(.semibold)
                .rotationEffect(.degrees(spins ? 360 : 0))
                .animation(spin, value: spinning)
        }
        .buttonStyle(.deckIcon())
        .help("Refresh now")
        .accessibilityLabel("Refresh")
    }
}

extension Meter {
    /// The value to headline: a percentage, or the amount used for dollar and count limits.
    var headline: String {
        switch format {
        case .percent: MetricFormatter.number(used, kind: .percent, style: .tray)
        case .dollars: MetricFormatter.number(used, kind: .dollars, style: .tray)
        case .count: MetricFormatter.number(used, kind: .count, style: .tray)
        }
    }

    /// Used of limit, like "$42 of $100", or the percentage.
    var detail: String {
        switch format {
        case .percent:
            return MetricFormatter.number(used, kind: .percent, style: .row)
        case .dollars:
            return "\(MetricFormatter.number(used, kind: .dollars, style: .row)) of "
                + MetricFormatter.number(limit, kind: .dollars, style: .row)
        case .count(let suffix):
            let unit = suffix.isEmpty ? "" : " \(suffix)"
            return "\(MetricFormatter.number(used, kind: .count, style: .row)) of "
                + "\(MetricFormatter.number(limit, kind: .count, style: .row))\(unit)"
        }
    }

    func resetLabel(now: Date) -> String? {
        resetsAt.flatMap { Formatters.resetRelativeLabel(until: $0, now: now) }
    }

    /// Whether it will last until it resets, when the provider says how long its window is.
    func pace(now: Date) -> Pace.Result? {
        guard let resetsAt, let period else { return nil }
        return Pace.evaluate(used: used, limit: limit, resetsAt: resetsAt, periodDuration: period, now: now)
    }
}
