// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

/// The Network tab: the speed now over a graph of the last minute, beside the history as bars by
/// the hour, day, or month. Download is the bright one and upload the quiet one, in the graph, the
/// totals and the bars alike.
struct NetworkView: View {
    let network: NetworkFeature

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: Deck.Metric.gap) {
                LiveCard(network: network)
                    .frame(width: min(max(proxy.size.width * 0.38, 132), 230))
                HistoryCard(network: network)
            }
        }
    }
}

/// The download's speed, big, with the upload's under it, over the last minute's graph.
private struct LiveCard: View {
    let network: NetworkFeature

    var body: some View {
        let rate = network.rate
        let down = NetworkFeature.speed(rate.down)
        let up = NetworkFeature.speed(rate.up)
        DeckCard {
            VStack(alignment: .leading, spacing: 6) {
                // The minute's peak joins the caption where there's room for both.
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("Download").deckText(.caption)
                        Spacer(minLength: 6)
                        if let peak = network.recent.map(\.rate.down).max(), peak > 0 {
                            let speed = NetworkFeature.speed(peak)
                            Text("peak \(speed.value) \(speed.unit)").deckText(.caption)
                        }
                    }
                    Text("Download").deckText(.caption)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(down.value).deckText(.metric)
                    Text(down.unit).deckText(.detail)
                }
                HStack {
                    Text("Upload").deckText(.caption)
                    Spacer(minLength: 6)
                    Text("\(up.value) \(up.unit)").deckText(.body)
                }
                // ponytail: no rolling digits. A numericText transition on a number that changes every
                // second kept the open tab at 12-51% of a core (0.5% without); roll them only if that changes.
                Sparkline(samples: network.recent).padding(.top, 4)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Network speed")
        .accessibilityValue("\(Self.spoken(down)) down, \(Self.spoken(up)) up")
    }

    static func spoken(_ speed: (value: String, unit: String)) -> String {
        "\(speed.value) \(speed.unit.replacingOccurrences(of: "/s", with: " per second"))"
    }
}

/// The last minute of speed: the download as a bright area with a dot on its latest reading, and the
/// upload as a quiet line. Scaled to the minute's peak, never below 100 KB/s, so idle chatter stays a
/// ripple. Drawn once per reading, never animated in between.
private struct Sparkline: View {
    let samples: [RateSample]

    var body: some View {
        Canvas { context, size in
            let baseline = Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1))
            context.fill(baseline, with: .color(Deck.hairline))
            guard samples.count > 1, let latest = samples.last?.at else { return }
            let peak = max(samples.map { max($0.rate.down, $0.rate.up) }.max() ?? 0, 100_000)
            let top: CGFloat = 8
            let width = size.width - 5  // room for the dot on the latest reading
            func points(_ value: (Rate) -> Double) -> [CGPoint] {
                samples.map { sample in
                    CGPoint(
                        x: width * (1 - latest.timeIntervalSince(sample.at) / NetworkFeature.window),
                        y: size.height - 1 - (size.height - top - 1) * min(value(sample.rate) / peak, 1))
                }
            }
            let down = points(\.down)
            let line = Self.smooth(down)
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: down[down.count - 1].y))  // on past the dot to the edge
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: down[0].x, y: size.height))
            area.closeSubpath()
            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [Deck.text.opacity(0.3), Deck.text.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(
                Self.smooth(points(\.up)), with: .color(Deck.tertiary),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            context.stroke(
                line, with: .color(Deck.text), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            let head = down[down.count - 1]
            context.fill(
                Path(ellipseIn: CGRect(x: head.x - 3, y: head.y - 3, width: 6, height: 6)), with: .color(Deck.text))
        }
        .accessibilityHidden(true)
    }

    /// Through the midpoints between readings, curving at each reading: smooth without overshooting.
    private static func smooth(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for (previous, point) in zip(points, points.dropFirst()) {
            path.addQuadCurve(
                to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2), control: previous)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

/// The history: a range switch, the range's download, upload, and total (or the bar under the
/// pointer's), and its bars.
private struct HistoryCard: View {
    let network: NetworkFeature

    @State private var picked: Int?

    var body: some View {
        let buckets = network.buckets
        let bar = picked.flatMap { buckets.indices.contains($0) ? buckets[$0] : nil }
        let traffic = bar?.traffic ?? buckets.reduce(Traffic()) { $0 + $1.traffic }
        DeckCard {
            VStack(alignment: .leading, spacing: Deck.Metric.gap) {
                HStack {
                    DeckSegmented(HistoryRange.allCases, selection: network.range, title: \.title) { range in
                        picked = nil
                        network.range = range
                    }
                    .fixedSize()
                    Spacer(minLength: Deck.Metric.gap)
                    // The bar under the pointer says which one it is.
                    if let bar { Text(network.range.label(bar.start)).deckText(.detail).lineLimit(1) }
                }
                Totals(traffic: traffic)
                Bars(buckets: buckets, range: network.range, picked: $picked)
                if let first = buckets.first, let last = buckets.last {
                    HStack {
                        Text(network.range.axisLabel(first.start))
                        Spacer()
                        Text(network.range.axisLabel(buckets[buckets.count / 2].start))
                        Spacer()
                        Text(network.range.axisLabel(last.start))
                    }
                    .deckText(.caption)
                    .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Download, upload, and the two together: three columns, the first two keyed to the bars' shades.
private struct Totals: View {
    let traffic: Traffic

    var body: some View {
        HStack(alignment: .top, spacing: Deck.Metric.gap) {
            column("Download", traffic.down, dot: Deck.text)
            column("Upload", traffic.up, dot: Deck.tertiary)
            column("Total", traffic.total, dot: nil)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(NetworkFeature.bytes(traffic.down)) down, \(NetworkFeature.bytes(traffic.up)) up, "
                + "\(NetworkFeature.bytes(traffic.total)) in all")
    }

    private func column(_ title: String, _ bytes: Int64, dot: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(title).deckText(.caption)
            }
            Text(NetworkFeature.bytes(bytes)).deckText(.item)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The range as bars, download under upload, scaled to the tallest. The pointer picks a bar and the
/// others dim.
private struct Bars: View {
    let buckets: [TrafficBucket]
    let range: HistoryRange
    @Binding var picked: Int?

    var body: some View {
        GeometryReader { proxy in
            let peak = CGFloat(max(buckets.map(\.traffic.total).max() ?? 0, 1))
            let count = CGFloat(max(buckets.count, 1))
            let gap: CGFloat = buckets.count > 12 ? 2 : 4
            let width = max(1, (proxy.size.width - gap * (count - 1)) / count)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(buckets.enumerated()), id: \.offset) { index, bucket in
                    Bar(traffic: bucket.traffic, width: width, scale: proxy.size.height / peak)
                        .opacity(picked == nil || picked == index ? 1 : 0.35)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                // Every pointer move lands here; only crossing into another bar changes anything.
                var bar: Int?
                if case .active(let location) = phase {
                    bar = min(max(Int(location.x / (width + gap)), 0), buckets.count - 1)
                }
                if bar != picked { picked = bar }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(range.caption)
        .accessibilityValue(spokenValue)
        .accessibilityAdjustableAction { direction in
            let next = (picked ?? buckets.count) + (direction == .increment ? 1 : -1)
            picked = buckets.indices.contains(next) ? next : nil
        }
    }

    private var spokenValue: String {
        let traffic: Traffic
        var prefix = ""
        if let picked, buckets.indices.contains(picked) {
            traffic = buckets[picked].traffic
            prefix = range.label(buckets[picked].start) + ", "
        } else {
            traffic = buckets.reduce(Traffic()) { $0 + $1.traffic }
        }
        return "\(prefix)\(NetworkFeature.bytes(traffic.down)) down, \(NetworkFeature.bytes(traffic.up)) up, "
            + "\(NetworkFeature.bytes(traffic.total)) in all"
    }
}

/// Upload stacked on download, rounded on top, or a sliver while empty so the row keeps its shape.
private struct Bar: View {
    let traffic: Traffic
    let width: CGFloat
    /// Points per byte.
    let scale: CGFloat

    var body: some View {
        let radius = min(width / 2, 3)
        ZStack(alignment: .bottom) {
            Rectangle().fill(traffic.total == 0 ? Deck.control : Deck.tertiary)
            Rectangle().fill(Deck.text).frame(height: CGFloat(traffic.down) * scale)
        }
        .frame(width: width, height: max(CGFloat(traffic.total) * scale, 2))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius, style: .continuous))
    }
}

extension HistoryRange {
    /// Under the chart: "3 PM", "Mon", "12 Sep", or "Sep".
    func axisLabel(_ date: Date) -> String {
        switch self {
        case .day: date.formatted(.dateTime.hour())
        case .week: date.formatted(.dateTime.weekday(.abbreviated))
        case .month: date.formatted(.dateTime.day().month(.abbreviated))
        case .year: date.formatted(.dateTime.month(.abbreviated))
        }
    }

    /// A bar in full: "Tue 3 PM", "Tue 12 Sep", or "September 2026".
    func label(_ date: Date) -> String {
        switch self {
        case .day: date.formatted(.dateTime.weekday(.abbreviated).hour())
        case .week, .month: date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .year: date.formatted(.dateTime.month(.wide).year())
        }
    }
}
