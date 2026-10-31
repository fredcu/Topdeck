// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

/// The Mac page's left side, as the board: six cards in three columns by two rows (CPU, GPU, network, disk,
/// memory, battery), each an icon, a large value, a sparkline of the last minute and a line of detail; and
/// under them the busiest processes, as many rows as fit, sorted by a click on a header. A Mac without a
/// battery shows its uptime in the last card.
public struct PerformanceView: View {
    let performance: PerformanceFeature

    @State private var sort = ProcessSort.cpu

    public init(performance: PerformanceFeature) { self.performance = performance }

    public var body: some View {
        let snapshot = performance.snapshot
        let history = performance.history
        VStack(spacing: 8) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    cpu(snapshot, history)
                    gpu(snapshot, history)
                    network(snapshot, history)
                }
                GridRow {
                    disk(snapshot, history)
                    memory(snapshot, history)
                    battery(snapshot, history)
                }
            }
            ProcessTable(snapshot: snapshot, sort: $sort)
        }
        .monospacedDigit()
    }

    // MARK: Cards

    private func cpu(_ snapshot: PerformanceFeature.Snapshot, _ history: PerformanceHistory) -> some View {
        let temperature = MacFormat.degrees(snapshot.temperatures?.chip)
        return MetricCard(
            icon: .cpu, tint: Deck.Accent.mac, detail: ["CPU", temperature].compactMap { $0 }.joined(separator: ", "),
            value: MacFormat.whole(snapshot.cpu), unit: "%", history: history.cpu.values, floor: 10,
            line: snapshot.loadAverage.map { String(format: "Load %.2f", $0) } ?? "",
            spoken: "CPU \(MacFormat.whole(snapshot.cpu)) percent")
    }

    private func gpu(_ snapshot: PerformanceFeature.Snapshot, _ history: PerformanceHistory) -> some View {
        let temperature = MacFormat.degrees(snapshot.temperatures?.gpu)
        return MetricCard(
            icon: .gpu, tint: Deck.Accent.tools,
            detail: ["GPU", temperature].compactMap { $0 }.joined(separator: ", "),
            value: MacFormat.whole(snapshot.gpu), unit: "%", history: history.gpu.values, floor: 10,
            line: snapshot.chipName ?? "", spoken: "GPU \(MacFormat.whole(snapshot.gpu)) percent")
    }

    private func network(_ snapshot: PerformanceFeature.Snapshot, _ history: PerformanceHistory) -> some View {
        let traffic = MacFormat.traffic(snapshot.network)
        return MetricCard(
            icon: .globe, tint: Deck.Accent.now, detail: snapshot.networkInterface ?? "Network", value: traffic.value,
            unit: traffic.unit, history: history.network.values, floor: 1000, line: traffic.detail,
            spoken: "Network \(traffic.value) \(traffic.unit)")
    }

    private func disk(_ snapshot: PerformanceFeature.Snapshot, _ history: PerformanceHistory) -> some View {
        let free = MacFormat.bytes(snapshot.diskFree)
        return MetricCard(
            icon: .disk, tint: Deck.Tint.magenta,
            detail: snapshot.diskTotal.map { MacFormat.capacity($0, memory: false) } ?? "",
            value: free.value, unit: "\(free.unit) free", history: history.disk.values, floor: 1000,
            line: MacFormat.disk(read: snapshot.diskRead, written: snapshot.diskWritten),
            spoken: "Disk, \(free.value) \(free.unit) free")
    }

    private func memory(_ snapshot: PerformanceFeature.Snapshot, _ history: PerformanceHistory) -> some View {
        let sample = snapshot.memory
        let percent = sample.flatMap { $0.total > 0 ? $0.used / $0.total * 100 : nil }
        return MetricCard(
            icon: .memory, tint: Deck.Tint.yellow,
            detail: sample.map { MacFormat.capacity(Int64($0.total), memory: true) } ?? "",
            value: MacFormat.whole(percent), unit: "%", history: history.memory.values, ceiling: 100,
            line: sample.map { "Used \(MacFormat.gigabytes($0.used))" } ?? "",
            tone: snapshot.pressure == .normal ? nil : (snapshot.pressure == .warning ? .signal : .stop),
            spoken: "Memory \(MacFormat.whole(percent)) percent, pressure \(snapshot.pressure.title)")
    }

    @ViewBuilder private func battery(_ snapshot: PerformanceFeature.Snapshot, _ history: PerformanceHistory)
        -> some View
    {
        if let battery = snapshot.battery {
            MetricCard(
                icon: .battery, tint: Deck.Accent.mac, detail: MacFormat.degrees(snapshot.temperatures?.battery) ?? "",
                value: "\(battery.percent)", unit: "%", history: history.battery.values, ceiling: 100,
                line: battery.health.map { "Health \($0)%" } ?? "", spoken: "Battery \(battery.percent) percent")
        } else {
            // A Mac without a battery: how long it has been on.
            let uptime = MacFormat.uptime(ProcessInfo.processInfo.systemUptime)
            MetricCard(
                icon: .bolt, tint: Deck.Accent.mac, detail: "AC", value: uptime, unit: "", history: [], floor: 1,
                line: "",
                spoken: "Up \(uptime)")
        }
    }
}

// MARK: Pieces

/// One card: a tinted icon and a detail, the value with its unit, a sparkline and a line of detail.
private struct MetricCard: View {
    let icon: DeckIcon
    let tint: Color
    let detail: String
    let value: String
    let unit: String
    let history: [Double]
    var floor: Double = 1
    var ceiling: Double?
    let line: String
    var tone: DeckTone?
    let spoken: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                DeckIconView(icon, size: 13)
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.tint(0.2)))
                Spacer(minLength: 4)
                Text(detail).deckText(.caption).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit).deckText(.caption).lineLimit(1)
                if let tone {
                    Spacer(minLength: 0)
                    DeckDot(tone)
                }
            }
            MetricSparkline(values: history, color: tint, floor: floor, ceiling: ceiling).frame(height: 24)
            Text(line).font(.system(size: 11)).foregroundStyle(Deck.tertiary).lineLimit(1).frame(
                height: 14, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Deck.Radius.tile, style: .continuous).fill(Deck.card))
        .overlay(
            RoundedRectangle(cornerRadius: Deck.Radius.tile, style: .continuous).strokeBorder(
                Deck.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
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

/// The busiest processes: a header to sort by, then as many rows as the height has room for.
private struct ProcessTable: View {
    let snapshot: PerformanceFeature.Snapshot
    @Binding var sort: ProcessSort

    private static let rowHeight: CGFloat = 24
    private static let headerHeight: CGFloat = 22

    var body: some View {
        GeometryReader { space in
            let fit = Int((space.size.height - Self.headerHeight) / Self.rowHeight)
            // Under one row there is nothing to sort: the table makes room for the cards first.
            if fit >= 1 {
                VStack(spacing: 0) {
                    header
                    ForEach(sort.rows(in: snapshot, limit: fit)) { process in
                        HStack(spacing: 8) {
                            Text(process.name).deckText(.body).lineLimit(1).frame(
                                maxWidth: .infinity, alignment: .leading)
                            Text(MacFormat.processCPU(process.cpu)).deckText(.detail).frame(
                                width: 44, alignment: .trailing)
                            Text(MacFormat.processMemory(process.memory)).deckText(.detail)
                                .frame(width: 58, alignment: .trailing)
                        }
                        .frame(height: Self.rowHeight)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            title("Process", .name).frame(maxWidth: .infinity, alignment: .leading)
            title("CPU", .cpu).frame(width: 44, alignment: .trailing)
            title("Memory", .memory).frame(width: 58, alignment: .trailing)
        }
        .frame(height: Self.headerHeight)
    }

    private func title(_ text: String, _ key: ProcessSort) -> some View {
        Button {
            sort = key
        } label: {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(sort == key ? Deck.text : Deck.tertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(text)")
        .accessibilityAddTraits(sort == key ? .isSelected : [])
    }
}
