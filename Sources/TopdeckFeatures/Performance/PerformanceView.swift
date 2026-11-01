// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

/// The Mac page's left side, as the board: a thermal strip (the system's verdict on heat, then CPU, GPU, SSD
/// and battery temperatures), and under it six tiles in three columns by two rows (CPU, GPU, network, memory,
/// storage, battery), each with its name and a detail, a large value, a chart or a bar of the last minute and
/// a line of detail. A Mac without a battery shows its uptime in the last tile.
public struct PerformanceView: View {
    let performance: PerformanceFeature

    public init(performance: PerformanceFeature) { self.performance = performance }

    /// Under this body height the strip drops its peak line and the tiles their captions.
    static let compactBelow: CGFloat = 320
    /// Under this width the strip's state block and gaps are tighter.
    static let narrowBelow: CGFloat = 430
    static let stripHeight: CGFloat = 52
    static let gap: CGFloat = 10

    public var body: some View {
        let snapshot = performance.snapshot
        let history = performance.history
        GeometryReader { space in
            let compact = space.size.height < Self.compactBelow
            // The two rows share what the strip leaves, charts 1.45 to the bars' 1.
            let rows = space.size.height - Self.stripHeight - 2 * Self.gap
            let top = max(rows * 1.45 / 2.45, 0)
            VStack(spacing: Self.gap) {
                ThermalStrip(snapshot: snapshot, compact: compact, narrow: space.size.width < Self.narrowBelow)
                    .frame(height: Self.stripHeight)
                HStack(spacing: Self.gap) {
                    cpu(snapshot, history, compact)
                    gpu(snapshot, history, compact)
                    network(snapshot, history, compact)
                }
                .frame(height: top)
                HStack(spacing: Self.gap) {
                    memory(snapshot, compact)
                    storage(snapshot, compact)
                    battery(snapshot, compact)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .monospacedDigit()
    }

    // MARK: Tiles

    private func cpu(_ snapshot: PerformanceFeature.Snapshot, _ history: PerformanceHistory, _ compact: Bool)
        -> some View
    {
        let cores = snapshot.efficiencyCores.count + snapshot.performanceCores.count
        return MetricTile(
            name: "CPU", detail: cores > 0 ? "\(cores) cores" : "", value: MacFormat.whole(snapshot.cpu), unit: "%",
            visual: .line(history.cpu.values, tint: Deck.Accent.mac, floor: 10),
            caption: snapshot.loadAverage.map { String(format: "Load %.2f", $0) } ?? "", compact: compact)
    }

    private func gpu(_ snapshot: PerformanceFeature.Snapshot, _ history: PerformanceHistory, _ compact: Bool)
        -> some View
    {
        MetricTile(
            name: "GPU", detail: snapshot.chipName ?? "", value: MacFormat.whole(snapshot.gpu), unit: "%",
            visual: .line(history.gpu.values, tint: Deck.Accent.tools, floor: 10),
            caption: (snapshot.gpu ?? 100) < 1 ? "Idle" : "", compact: compact)
    }

    private func network(_ snapshot: PerformanceFeature.Snapshot, _ history: PerformanceHistory, _ compact: Bool)
        -> some View
    {
        let traffic = MacFormat.traffic(snapshot.network)
        return MetricTile(
            name: snapshot.networkInterface ?? "Network", detail: "", value: traffic.value, unit: traffic.unit,
            visual: .line(history.network.values, tint: Deck.Accent.now, floor: 1000), caption: traffic.detail,
            compact: compact)
    }

    private func memory(_ snapshot: PerformanceFeature.Snapshot, _ compact: Bool) -> some View {
        let sample = snapshot.memory
        let percent = sample.flatMap { $0.total > 0 ? $0.used / $0.total * 100 : nil }
        // App, wired and compressed memory, each lighter than the one before.
        let parts = sample.map { sample in
            [(sample.active, 1.0), (sample.wired, 0.55), (sample.compressed, 0.3)].map {
                (fraction: $0.0 / max(sample.total, 1), strength: $0.1)
            }
        }
        return MetricTile(
            name: "Memory", detail: sample.map { MacFormat.capacity(Int64($0.total), memory: true) } ?? "",
            value: MacFormat.whole(percent), unit: "%", visual: .bar(parts ?? [], tint: Deck.Tint.yellow),
            caption: sample.map { "\(MacFormat.gigabytes($0.used)) used" } ?? "",
            tone: snapshot.pressure == .normal ? nil : (snapshot.pressure == .warning ? .signal : .stop),
            compact: compact)
    }

    private func storage(_ snapshot: PerformanceFeature.Snapshot, _ compact: Bool) -> some View {
        let free = MacFormat.bytes(snapshot.diskFree)
        var used = 0.0
        if let free = snapshot.diskFree, let total = snapshot.diskTotal, total > 0 {
            used = 1 - Double(free) / Double(total)
        }
        return MetricTile(
            name: "Storage", detail: snapshot.diskTotal.map { MacFormat.capacity($0, memory: false) } ?? "",
            value: free.value, unit: "\(free.unit) free", visual: .bar([(used, 1)], tint: Deck.Tint.magenta),
            caption: MacFormat.disk(read: snapshot.diskRead, written: snapshot.diskWritten), compact: compact)
    }

    @ViewBuilder private func battery(_ snapshot: PerformanceFeature.Snapshot, _ compact: Bool) -> some View {
        if let battery = snapshot.battery {
            MetricTile(
                name: "Battery", detail: battery.health.map { "Health \($0)%" } ?? "", value: "\(battery.percent)",
                unit: "%", visual: .bar([(Double(battery.percent) / 100, 1)], tint: Deck.Accent.mac),
                caption: MacFormat.battery(battery), compact: compact, hidesDetail: true)
        } else {
            // A Mac without a battery: how long it has been on.
            MetricTile(
                name: "Uptime", detail: "", value: MacFormat.uptime(ProcessInfo.processInfo.systemUptime), unit: "",
                visual: .none, caption: "", compact: compact)
        }
    }
}

// MARK: Thermal strip

extension Heat {
    fileprivate var color: Color {
        switch self {
        case .cool: Deck.Accent.now
        case .warm: Deck.Tint.yellow
        case .hot: Deck.Accent.tools
        case .critical: Deck.stop
        }
    }
}

/// The system's thermal state at the left, then the four temperatures, each with a gauge that fills to its
/// reading over 110° in the colour of its heat. A Mac that reports no temperatures shows the state alone.
private struct ThermalStrip: View {
    let snapshot: PerformanceFeature.Snapshot
    let compact: Bool
    let narrow: Bool

    private struct Reading: Identifiable {
        let name: String
        let value: Double?
        var peak: Double?
        var id: String { name }
    }

    var body: some View {
        let temperatures = snapshot.temperatures
        let readings = [
            Reading(name: "CPU", value: temperatures?.chip, peak: temperatures?.chipHottest),
            Reading(name: "GPU", value: temperatures?.gpu), Reading(name: "SSD", value: temperatures?.ssd),
            Reading(name: "Battery", value: temperatures?.battery),
        ]
        HStack(spacing: narrow ? 8 : 10) {
            state.frame(width: narrow ? 62 : 76, alignment: .leading)
            if temperatures != nil {
                Rectangle().fill(Deck.hairline).frame(width: 1).padding(.vertical, 10)
                ForEach(readings) { reading in
                    ReadingView(reading: reading, showsPeak: !compact).frame(maxWidth: .infinity)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, narrow ? 10 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Deck.Radius.tile + 2, style: .continuous).fill(Deck.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Deck.Radius.tile + 2, style: .continuous).strokeBorder(
                Deck.hairline, lineWidth: 1)
        )
    }

    private var state: some View {
        let level = snapshot.thermal
        let color: Color =
            switch level {
            case .normal: Deck.go
            case .fair: Deck.secondary
            case .throttling: Deck.signal
            }
        return VStack(alignment: .leading, spacing: 2) {
            Text("Thermal").font(.system(size: 12, weight: .semibold)).foregroundStyle(Deck.secondary)
            Text(level.title).font(.system(size: 13, weight: .bold)).foregroundStyle(color)
        }
        .lineLimit(1)
        // "Throttling" keeps its width; the readings beside it give way.
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thermal state")
        .accessibilityValue(level.title)
    }

    private struct ReadingView: View {
        let reading: Reading
        let showsPeak: Bool

        var body: some View {
            let heat = reading.value.map { Heat(degrees: $0) }
            let color = heat?.color ?? Deck.tertiary
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    // The name gives way first where the strip is short of room.
                    Text(reading.name).font(.system(size: 11.5)).foregroundStyle(Deck.tertiary)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Spacer(minLength: 0)
                    Text(MacFormat.degrees(reading.value) ?? "–")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(heat?.tintsReading == true ? color : Deck.text)
                        .lineLimit(1).fixedSize()
                }
                Capsule().fill(Deck.control).frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { track in
                            if let value = reading.value {
                                Capsule().fill(color).frame(width: track.size.width * Heat.gauge(value))
                            }
                        }
                    }
                if showsPeak, let peak = reading.peak, let text = MacFormat.degrees(peak) {
                    Text("peak \(text)").font(.system(size: 11.5)).foregroundStyle(Deck.tertiary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(reading.name) temperature")
            .accessibilityValue(spoken)
        }

        private var spoken: String {
            guard let value = reading.value else { return "No reading" }
            let degrees = "\(Int(value.rounded())) degrees"
            return reading.peak.map { "\(degrees), peak \(Int($0.rounded()))" } ?? degrees
        }
    }
}

// MARK: Tiles

/// One tile: its name and a detail, the value with its unit, a chart or a bar and a line of detail.
private struct MetricTile: View {
    enum Visual {
        /// The last minute as a line, scaled to its largest value (at least `floor`).
        case line([Double], tint: Color, floor: Double)
        /// A bar in parts of the whole, each with its own strength of the tint.
        case bar([(fraction: Double, strength: Double)], tint: Color)
        case none
    }

    let name: String
    let detail: String
    let value: String
    let unit: String
    let visual: Visual
    let caption: String
    var tone: DeckTone?
    /// The smallest deck: no caption line (and for the battery no detail); they stay in the tooltip.
    let compact: Bool
    var hidesDetail = false

    var body: some View {
        let shown = compact && hidesDetail ? "" : detail
        let spoken = [name, detail, "\(value) \(unit)", caption].filter { !$0.isEmpty }.joined(separator: ", ")
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // The detail gives way first where the tile is narrow.
                Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Deck.secondary)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Text(shown).font(.system(size: 12)).foregroundStyle(Deck.tertiary).minimumScaleFactor(0.65)
            }
            .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
                Text(unit).font(.system(size: 14, weight: .semibold)).foregroundStyle(Deck.secondary)
                if let tone {
                    Spacer(minLength: 0)
                    DeckDot(tone)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.top, 4)
            chart.padding(.top, 6)
            if !compact, !caption.isEmpty {
                Text(caption).font(.system(size: 11.5)).foregroundStyle(Deck.tertiary).lineLimit(1).padding(.top, 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Deck.Radius.tile + 2, style: .continuous).fill(Deck.card))
        .overlay(
            RoundedRectangle(cornerRadius: Deck.Radius.tile + 2, style: .continuous).strokeBorder(
                Deck.hairline, lineWidth: 1)
        )
        .help(spoken)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    @ViewBuilder private var chart: some View {
        switch visual {
        case .line(let values, let tint, let floor):
            MetricSparkline(values: values, color: tint, floor: floor).frame(minHeight: 20)
        case .bar(let parts, let tint):
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                MetricBar(parts: parts, tint: tint)
            }
            .frame(minHeight: 20)
        case .none:
            Spacer(minLength: 0)
        }
    }
}

/// An 8 point bar of parts of the whole, each lighter than the one before, on the control colour.
private struct MetricBar: View {
    let parts: [(fraction: Double, strength: Double)]
    let tint: Color

    var body: some View {
        GeometryReader { track in
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Rectangle().fill(tint.opacity(part.strength))
                        .frame(width: track.size.width * min(max(part.fraction, 0), 1))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Deck.control)
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// A line over a faint fill. The scale runs from zero to the window's largest value, at least `floor`, or to
/// `ceiling` when there is one.
struct MetricSparkline: View {
    let values: [Double]
    let color: Color
    var floor: Double = 1
    var ceiling: Double?

    var body: some View {
        GeometryReader { space in
            let points = Self.points(values, in: space.size, floor: floor, ceiling: ceiling)
            if points.count > 1 {
                Path { path in
                    path.move(to: CGPoint(x: points[0].x, y: space.size.height))
                    for point in points { path.addLine(to: point) }
                    path.addLine(to: CGPoint(x: points[points.count - 1].x, y: space.size.height))
                }
                .fill(color.opacity(0.18))
                Path { path in
                    path.move(to: points[0])
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }

    /// The points, from the left edge to the right, the newest on the right; a short history is drawn
    /// across the width it would fill at a minute.
    nonisolated static func points(_ values: [Double], in size: CGSize, floor: Double, ceiling: Double?) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let top = ceiling ?? max(values.max() ?? 0, floor)
        let step = size.width / Double(values.count - 1)
        return values.enumerated().map { index, value in
            let level = min(max(value / max(top, .leastNonzeroMagnitude), 0), 1)
            return CGPoint(x: Double(index) * step, y: size.height - 1 - level * (size.height - 3))
        }
    }
}
