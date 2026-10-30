// SPDX-License-Identifier: MIT
import SwiftUI

/// The Monitors tab: each external monitor's brightness and volume, and a button that puts every
/// display to sleep.
struct MonitorsView: View {
    let monitors: MonitorsFeature

    var body: some View {
        if monitors.monitors.isEmpty {
            if monitors.hasLooked {
                FeatureUnavailableView(
                    symbol: "display",
                    title: "No external monitors",
                    message: "Connect a monitor to set its brightness and volume here.",
                    action: (label: "Sleep Displays", perform: monitors.sleepDisplays))
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 8) {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(monitors.monitors) { monitor in
                            MonitorRow(monitor: monitor) { control, level in
                                monitors.set(control, of: monitor.id, to: level)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.never)
                .fadingEdges()
                HStack {
                    Spacer()
                    Button(action: monitors.sleepDisplays) {
                        Label("Sleep Displays", systemImage: "moon.zzz.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct MonitorRow: View {
    let monitor: MonitorsFeature.Monitor
    let set: (DDC.Control, Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(monitor.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                switch monitor.status {
                case .checking where monitor.brightness == nil && monitor.volume == nil:
                    ProgressView().controlSize(.mini)
                case .unavailable:
                    Text("Unavailable").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                default:
                    EmptyView()
                }
            }
            if monitor.status != .unavailable, monitor.brightness != nil || monitor.volume != nil {
                HStack(spacing: 14) {
                    if let brightness = monitor.brightness {
                        LevelBar(symbol: "sun.max.fill", title: "\(monitor.name) brightness", level: brightness) {
                            set(.brightness, $0)
                        }
                    }
                    if let volume = monitor.volume {
                        LevelBar(symbol: Self.speaker(volume), title: "\(monitor.name) volume", level: volume) {
                            set(.volume, $0)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .opacity(monitor.status == .unavailable ? 0.6 : 1)
    }

    private static func speaker(_ level: Double) -> String {
        switch level {
        case 0: "speaker.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}

/// A level to drag, with its symbol and percentage.
// ponytail: like the Sound tab's LevelSlider, which lives in TopdeckMixer.
private struct LevelBar: View {
    let symbol: String
    let title: String
    let level: Double
    let set: (Double) -> Void

    private var percent: Int { Int((min(max(level, 0), 1) * 100).rounded()) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 15)
            GeometryReader { proxy in
                Capsule()
                    .fill(.white.opacity(0.12))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white).frame(width: max(6, proxy.size.width * min(max(level, 0), 1)))
                    }
                    .contentShape(Capsule().inset(by: -6))
                    .gesture(
                        DragGesture(minimumDistance: 0).onChanged { drag in
                            set(min(max(drag.location.x / max(proxy.size.width, 1), 0), 1))
                        })
            }
            .frame(height: 6)
            Text("\(percent)%")
                .monospacedDigit()
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 32, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(percent)%")
        .accessibilityAdjustableAction { direction in
            set(min(max(level + (direction == .increment ? 0.05 : -0.05), 0), 1))
        }
    }
}
