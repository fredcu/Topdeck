// SPDX-License-Identifier: MIT
import SwiftUI

/// The Performance tab: a grid of cards, the numbers first.
struct PerformanceView: View {
    let performance: PerformanceFeature

    var body: some View {
        let snapshot = performance.snapshot
        ScrollView {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    CPUCard(snapshot: snapshot)
                    VStack(spacing: 8) {
                        MemoryCard(snapshot: snapshot)
                        GPUCard(gpu: snapshot.gpu)
                    }
                }
                GridRow {
                    DiskCard(snapshot: snapshot)
                    NetworkCard(rate: snapshot.network)
                }
                GridRow {
                    TopAppsCard(snapshot: snapshot).gridCellColumns(2)
                }
                if snapshot.temperatures != nil || snapshot.battery != nil {
                    GridRow {
                        HStack(spacing: 8) {
                            if let temperatures = snapshot.temperatures { TemperatureCard(temperatures: temperatures) }
                            if let battery = snapshot.battery { BatteryCard(battery: battery) }
                        }
                        .gridCellColumns(2)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.trailing, 8)  // clear of the resize grip in the notch's corner
        }
        .scrollIndicators(.never)
        .fadingEdges(length: 6)
        .monospacedDigit()
    }
}

/// A faint tinted tile with a hairline edge, like the Network and AI Usage cards.
private struct Card<Content: View>: View {
    let title: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9, weight: .bold)).textCase(.uppercase).tracking(0.6)
                .foregroundStyle(.white.opacity(0.5))
            content
        }
        .lineLimit(1)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            shape.fill(
                LinearGradient(
                    colors: [tint.opacity(0.16), .white.opacity(0.03)], startPoint: .topLeading,
                    endPoint: .bottomTrailing))
        )
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

private func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "–" }

private func big(_ text: String) -> some View {
    Text(text).font(.system(size: 22, weight: .bold, design: .rounded))
}

private func small(_ text: String, _ color: Color = .white.opacity(0.7)) -> some View {
    Text(text).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(color)
}

private func speedText(_ bytesPerSecond: Double?) -> String {
    guard let bytesPerSecond else { return "–" }
    let speed = NetworkFeature.speed(bytesPerSecond)
    return "\(speed.value) \(speed.unit)"
}

private func bytes(_ count: Int64?) -> String {
    count.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "–"
}

private struct Meter: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(.white.opacity(0.12))
                .overlay(alignment: .leading) {
                    Capsule().fill(tint).frame(width: proxy.size.width * min(max(value / 100, 0), 1))
                }
        }
        .frame(height: 5)
    }
}

/// One bar per core, filling from the bottom.
private struct CoreBars: View {
    let loads: [Double]
    let tint: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(loads.enumerated()), id: \.offset) { _, load in
                Capsule().fill(.white.opacity(0.12))
                    .overlay(alignment: .bottom) {
                        GeometryReader { proxy in
                            Capsule().fill(tint).frame(height: proxy.size.height * min(max(load / 100, 0), 1))
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                    .frame(maxWidth: 8)
            }
        }
        .frame(height: 26)
    }
}

private struct CPUCard: View {
    let snapshot: PerformanceFeature.Snapshot

    var body: some View {
        Card(title: "CPU", tint: .green) {
            big(percent(snapshot.cpu))
            if !snapshot.efficiencyCores.isEmpty {
                HStack(spacing: 6) {
                    small("E")
                    CoreBars(loads: snapshot.efficiencyCores, tint: .mint)
                }
            }
            HStack(spacing: 6) {
                small("P")
                CoreBars(loads: snapshot.performanceCores, tint: .green)
            }
        }
        .accessibilityLabel("CPU \(percent(snapshot.cpu))")
    }
}

private struct MemoryCard: View {
    let snapshot: PerformanceFeature.Snapshot

    var body: some View {
        let used = snapshot.memory?.used ?? 0
        let total = snapshot.memory?.total ?? 0
        let tint: Color =
            switch snapshot.pressure {
            case .normal: .green
            case .warning: .yellow
            case .critical: .red
            }
        Card(title: "Memory", tint: tint) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 7, height: 7)
                small(snapshot.pressure.title)
            }
            small(
                "\(ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .memory)) of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .memory))"
            )
            Meter(value: total > 0 ? used / total * 100 : 0, tint: tint)
        }
        .accessibilityLabel("Memory pressure \(snapshot.pressure.title)")
    }
}

private struct GPUCard: View {
    let gpu: Double?

    var body: some View {
        if let gpu {
            Card(title: "GPU", tint: .purple) {
                small(percent(gpu))
                Meter(value: gpu, tint: .purple)
            }
        }
    }
}

private struct DiskCard: View {
    let snapshot: PerformanceFeature.Snapshot

    var body: some View {
        Card(title: "Disk", tint: .orange) {
            small("Read \(speedText(snapshot.diskRead))")
            small("Write \(speedText(snapshot.diskWritten))")
            small("\(bytes(snapshot.diskFree)) free", .white.opacity(0.5))
        }
    }
}

private struct NetworkCard: View {
    let rate: Rate?

    var body: some View {
        Card(title: "Network", tint: NetworkTint.down) {
            small("↓ \(speedText(rate?.down))", NetworkTint.downLight)
            small("↑ \(speedText(rate?.up))", NetworkTint.upLight)
        }
    }
}

private struct TopAppsCard: View {
    let snapshot: PerformanceFeature.Snapshot

    var body: some View {
        Card(title: "Top apps", tint: .blue) {
            HStack(alignment: .top, spacing: 14) {
                column(snapshot.topCPU) { "\(Int($0.cpu.rounded()))%" }
                column(snapshot.topMemory) {
                    ByteCountFormatter.string(fromByteCount: Int64($0.memory), countStyle: .memory)
                }
            }
        }
    }

    private func column(_ rows: [ProcessUsage], value: @escaping (ProcessUsage) -> String) -> some View {
        VStack(spacing: 2) {
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    small(row.name)
                    Spacer(minLength: 4)
                    small(value(row), .white.opacity(0.5))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct TemperatureCard: View {
    let temperatures: Temperatures

    var body: some View {
        Card(title: "Temperature", tint: .red) {
            if let chip = temperatures.chipHottest ?? temperatures.chip { row("Chip", chip) }
            if let ssd = temperatures.ssd { row("SSD", ssd) }
            if let battery = temperatures.battery { row("Battery", battery) }
        }
    }

    private func row(_ name: String, _ degrees: Double) -> some View {
        HStack {
            small(name)
            Spacer(minLength: 4)
            small("\(Int(degrees.rounded()))°C", .white.opacity(0.5))
        }
    }
}

private struct BatteryCard: View {
    let battery: BatteryReport

    var body: some View {
        Card(title: "Battery", tint: .green) {
            HStack {
                small("Charge")
                Spacer(minLength: 4)
                small("\(battery.percent)%", .white.opacity(0.5))
            }
            if let health = battery.health {
                HStack {
                    small("Health")
                    Spacer(minLength: 4)
                    small("\(health)%", .white.opacity(0.5))
                }
            }
            if let cycles = battery.cycleCount {
                HStack {
                    small("Cycles")
                    Spacer(minLength: 4)
                    small("\(cycles)", .white.opacity(0.5))
                }
            }
            if let watts = battery.adapterWatts {
                HStack {
                    small("Charger")
                    Spacer(minLength: 4)
                    small("\(watts) W", .white.opacity(0.5))
                }
            }
        }
    }
}
