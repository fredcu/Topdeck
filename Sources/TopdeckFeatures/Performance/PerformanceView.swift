// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

/// The Performance tab, as on the board: three columns by two rows of cards, the numbers first. CPU
/// is the wide one; the last card is Battery, or the network's speed on a Mac without one.
struct PerformanceView: View {
    let performance: PerformanceFeature

    var body: some View {
        let snapshot = performance.snapshot
        VStack(spacing: Deck.Metric.gap) {
            DeckWeightedRow([1.3, 1, 1]) {
                CPUCard(snapshot: snapshot)
                MemoryCard(snapshot: snapshot)
                GPUCard(snapshot: snapshot)
            }
            DeckWeightedRow([1.3, 1, 1]) {
                TopAppsCard(apps: snapshot.topCPU)
                DiskCard(snapshot: snapshot)
                if let battery = snapshot.battery {
                    BatteryCard(battery: battery)
                } else {
                    NetworkCard(rate: snapshot.network)
                }
            }
        }
        .monospacedDigit()
    }
}

// MARK: Pieces

/// A card with its caption at the top and its content spread down the rest of it.
private struct Tile<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).deckText(.caption)
                Spacer(minLength: 6)
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A figure on the left and what it is on the right: "98%  health".
@MainActor private func pair(_ value: String, _ name: String) -> some View {
    HStack {
        Text(value).deckText(.body).lineLimit(1)
        Spacer(minLength: Deck.Metric.gap)
        Text(name).deckText(.detail).lineLimit(1)
    }
}

private func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "–" }

private func speedText(_ bytesPerSecond: Double?) -> String {
    guard let bytesPerSecond else { return "–" }
    let speed = NetworkFeature.speed(bytesPerSecond)
    return "\(speed.value) \(speed.unit)"
}

// MARK: Cards

/// One bar per core, filling from the bottom: the efficiency cores quiet, the performance cores bright.
private struct CoreBars: View {
    let efficiency: [Double]
    let performance: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(efficiency.enumerated()), id: \.offset) { _, load in bar(load, Deck.tertiary) }
            ForEach(Array(performance.enumerated()), id: \.offset) { _, load in bar(load, Deck.text) }
        }
        .frame(height: 46)
        .accessibilityHidden(true)
    }

    private func bar(_ load: Double, _ color: Color) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(height: max(2, proxy.size.height * min(max(load / 100, 0), 1)))
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

private struct CPUCard: View {
    let snapshot: PerformanceFeature.Snapshot

    var body: some View {
        DeckCard {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("CPU").deckText(.caption)
                    Spacer(minLength: Deck.Metric.gap)
                    Text(percent(snapshot.cpu)).deckText(.metric)
                }
                Spacer(minLength: 6)
                CoreBars(efficiency: snapshot.efficiencyCores, performance: snapshot.performanceCores)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU \(percent(snapshot.cpu))")
    }
}

private struct MemoryCard: View {
    let snapshot: PerformanceFeature.Snapshot

    var body: some View {
        let used = snapshot.memory?.used ?? 0
        let total = snapshot.memory?.total ?? 0
        let tone: DeckTone? =
            switch snapshot.pressure {
            case .normal: nil
            case .warning: .signal
            case .critical: .stop
            }
        DeckCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("Memory").deckText(.caption)
                Text(String(format: "%.1f", used / Self.gigabyte)).deckText(.metric).padding(.top, 4)
                Spacer(minLength: 6)
                VStack(alignment: .leading, spacing: 5) {
                    DeckBar(total > 0 ? used / total : 0, tone: tone)
                    HStack(spacing: 6) {
                        Text("of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .memory))")
                            .deckText(.detail)
                        Spacer(minLength: 0)
                        // Normal needs no word; a warning is never only a color.
                        if let tone {
                            DeckDot(tone)
                            Text(snapshot.pressure.title).deckText(.detail)
                        }
                    }
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory pressure \(snapshot.pressure.title)")
        .accessibilityValue(
            "\(ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .memory)) of "
                + "\(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .memory))")
    }

    private static let gigabyte = 1_073_741_824.0
}

private struct GPUCard: View {
    let snapshot: PerformanceFeature.Snapshot

    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("GPU").deckText(.caption)
                Text(percent(snapshot.gpu)).deckText(.metric).padding(.top, 4)
                Spacer(minLength: 6)
                if let temperatures = snapshot.temperatures, let chip = temperatures.chipHottest ?? temperatures.chip {
                    HStack(spacing: 6) {
                        DeckIconView(.thermometer, size: 13)
                        Text("\(Int(chip.rounded()))° chip").deckText(.detail)
                    }
                    .foregroundStyle(Deck.secondary)
                    .help(Self.all(temperatures))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("GPU \(percent(snapshot.gpu))")
    }

    /// The temperatures the board has no room for, in the row's tooltip.
    private static func all(_ temperatures: Temperatures) -> String {
        [
            ("Chip", temperatures.chipHottest ?? temperatures.chip), ("SSD", temperatures.ssd),
            ("Battery", temperatures.battery),
        ]
        .compactMap { name, degrees in degrees.map { "\(name) \(Int($0.rounded()))°C" } }
        .joined(separator: "\n")
    }
}

private struct TopAppsCard: View {
    let apps: [ProcessUsage]

    var body: some View {
        Tile(title: "Top apps") {
            VStack(spacing: 6) {
                ForEach(apps.prefix(3)) { app in
                    HStack {
                        Text(app.name).deckText(.body).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: Deck.Metric.gap)
                        Text("\(Int(app.cpu.rounded()))%").deckText(.detail)
                    }
                }
            }
        }
    }
}

private struct DiskCard: View {
    let snapshot: PerformanceFeature.Snapshot

    var body: some View {
        Tile(title: "Disk") {
            VStack(spacing: 6) {
                pair(snapshot.diskFree.map { StorageFormat.bytes($0) } ?? "–", "free")
                pair(speedText(snapshot.diskRead), "read")
                pair(speedText(snapshot.diskWritten), "write")
            }
        }
    }
}

private struct BatteryCard: View {
    let battery: BatteryReport

    var body: some View {
        Tile(title: "Battery") {
            VStack(spacing: 6) {
                if let health = battery.health { pair("\(health)%", "health") }
                if let cycles = battery.cycleCount { pair("\(cycles)", "cycles") }
                if let watts = battery.adapterWatts { pair("\(watts) W", "charger") }
            }
        }
    }
}

/// Stands in for Battery on a Mac without one.
private struct NetworkCard: View {
    let rate: Rate?

    var body: some View {
        Tile(title: "Network") {
            VStack(spacing: 6) {
                pair(speedText(rate?.down), "down")
                pair(speedText(rate?.up), "up")
            }
        }
    }
}
