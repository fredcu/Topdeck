// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

/// The Displays tab: a card for each external monitor with its brightness and volume, and a button
/// that puts every display to sleep.
struct MonitorsView: View {
    let monitors: MonitorsFeature

    var body: some View {
        VStack(spacing: Deck.Metric.gap) {
            if monitors.monitors.isEmpty {
                if monitors.hasLooked {
                    DeckEmptyLine("No external monitors")
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    VStack(spacing: Deck.Metric.gap) {
                        ForEach(monitors.monitors) { monitor in
                            MonitorCard(monitor: monitor) { control, level in
                                monitors.set(control, of: monitor.id, to: level)
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer(minLength: 0)
                Button(action: monitors.sleepDisplays) {
                    HStack(spacing: 6) {
                        DeckIconView(.moon, size: 13)
                        Text("Sleep Displays")
                    }
                }
                .buttonStyle(.deck())
            }
        }
    }
}

private struct MonitorCard: View {
    let monitor: MonitorsFeature.Monitor
    let set: (DDC.Control, Double) -> Void

    var body: some View {
        DeckCard(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: Deck.Metric.gap) {
                    DeckIconView(.display)
                    Text(monitor.name).deckText(.item).lineLimit(1)
                    Spacer(minLength: 0)
                    switch monitor.status {
                    case .checking where monitor.brightness == nil && monitor.volume == nil:
                        ProgressView().controlSize(.mini)
                    case .unavailable:
                        Text("Unavailable").deckText(.caption)
                    default:
                        EmptyView()
                    }
                }
                .frame(minHeight: 38)
                if monitor.status != .unavailable {
                    if let brightness = monitor.brightness {
                        DeckLevelRow(
                            "Brightness", level: brightness, value: "\(percent(brightness))",
                            label: "\(monitor.name) brightness", set: { set(.brightness, $0) }
                        )
                        .help(
                            monitor.dimsPicture ? "Dims the picture; the monitor's own brightness stays the same." : "")
                    }
                    if let volume = monitor.volume {
                        DeckLevelRow(
                            "Volume", level: volume, value: "\(percent(volume))", label: "\(monitor.name) volume",
                            set: { set(.volume, $0) })
                    }
                }
            }
            .padding(.horizontal, Deck.Metric.cardPadding)
            .padding(.vertical, 6)
        }
        .opacity(monitor.status == .unavailable ? 0.6 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(monitor.name)
    }

    private func percent(_ level: Double) -> Int { Int((min(max(level, 0), 1) * 100).rounded()) }
}
