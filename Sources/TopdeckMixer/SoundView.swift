// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckFeatures
import TopdeckSurface

/// The Sound tab, as on the board: the Mac's outputs, then its inputs, to switch between on the left;
/// on the right one card of sliders: the output's volume, the microphone's, each app playing sound
/// (click its icon to mute), then each external monitor's volume.
public struct SoundView: View {
    let mixer: Mixer
    let monitors: MonitorsFeature?

    public init(mixer: Mixer, monitors: MonitorsFeature? = nil) {
        self.mixer = mixer
        self.monitors = monitors
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Deck.Metric.gap) {
            devices.frame(width: 208)
            levels.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear { mixer.appeared() }
        .onDisappear { mixer.disappeared() }
    }

    // MARK: Devices

    private var devices: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(mixer.outputs) { row($0, current: $0.id == mixer.output?.id, direction: .output) }
                if !mixer.outputs.isEmpty, !mixer.inputs.isEmpty {
                    DeckSeparator().padding(.horizontal, 10).padding(.vertical, 6)
                }
                ForEach(mixer.inputs) { row($0, current: $0.id == mixer.input?.id, direction: .input) }
            }
        }
    }

    private func row(_ device: SoundDevice, current: Bool, direction: SoundDirection) -> some View {
        DeckRow(selected: current) {
            mixer.choose(device, for: direction)
        } content: {
            DeckIconView(Self.icon(device.symbol, direction))
                .foregroundStyle(current ? Deck.text : Deck.tertiary)
            Text(Self.shortName(device.name)).deckText(.body).lineLimit(1)
            Spacer(minLength: 0)
            if current { DeckIconView(.check, size: 13) }
        }
        .help(device.name)
        .accessibilityLabel(device.name)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    /// The board's three: a display, a microphone, and speakers for everything else that plays.
    private static func icon(_ symbol: String, _ direction: SoundDirection) -> DeckIcon {
        if direction == .input { return .microphone }
        return symbol == "tv" || symbol.hasPrefix("display") ? .display : .volume
    }

    // MARK: Levels

    private var levels: some View {
        DeckCard(padding: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    if mixer.needsPermission { permission }
                    if let output = mixer.output { deviceRow(output, .output) }
                    if let input = mixer.input { deviceRow(input, .input) }
                    if !mixer.apps.isEmpty {
                        DeckSeparator()
                        ForEach(mixer.apps) { appRow($0) }
                    }
                    if let monitors, monitors.monitors.contains(where: { $0.volume != nil }) {
                        DeckSeparator()
                        ForEach(monitors.monitors.filter { $0.volume != nil }) { monitorRow($0, monitors) }
                    }
                }
                .padding(.horizontal, Deck.Metric.cardPadding)
                .padding(.vertical, 6)
            }
            .fadingEdges(length: 6)
        }
    }

    private func deviceRow(_ device: DeviceLevel, _ direction: SoundDirection) -> some View {
        let output = direction == .output
        let name = Self.shortName(device.name)
        return DeckLevelRow(
            output ? "Output" : "Input", style: .item, level: device.isMuted ? 0 : device.level,
            value: !device.hasVolume ? "–" : device.isMuted ? "Mute" : "\(Self.percent(device.level))",
            spoken: device.isMuted ? "Muted" : nil, enabled: device.hasVolume,
            set: { mixer.setDeviceLevel($0, for: direction) }
        ) {
            Button {
                mixer.toggleDeviceMute(direction)
            } label: {
                DeckIconView(output ? .volume : .microphone).opacity(device.isMuted ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .help(device.isMuted ? "Unmute \(name)" : "Mute \(name)")
            .accessibilityLabel(device.isMuted ? "Unmute \(name)" : "Mute \(name)")
        }
        .help(device.name)
    }

    private func appRow(_ app: MixerApp) -> some View {
        let muted = mixer.isMuted(app.id)
        return DeckLevelRow(
            app.name, level: muted ? 0 : mixer.level(of: app.id),
            value: muted ? "Mute" : "\(Self.percent(mixer.level(of: app.id)))", spoken: muted ? "Muted" : nil,
            set: { mixer.setLevel($0, of: app.id) }
        ) {
            Button {
                mixer.toggleMute(app.id)
            } label: {
                Image(nsImage: mixer.icon(for: app))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
                    .saturation(muted ? 0 : 1)
                    .opacity(muted ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .help(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
            .accessibilityLabel(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
        }
        .contextMenu {
            Button(muted ? "Unmute" : "Mute") { mixer.toggleMute(app.id) }
            if mixer.isAdjusted(app.id) { Button("Reset to 100%") { mixer.reset(app.id) } }
        }
    }

    private func monitorRow(_ monitor: MonitorsFeature.Monitor, _ monitors: MonitorsFeature) -> some View {
        let volume = monitor.volume ?? 0
        return DeckLevelRow(
            monitor.name, level: volume, value: "\(Self.percent(volume))",
            set: { monitors.setVolume($0, of: monitor.id) }, lead: { DeckIconView(.display) })
    }

    private static func percent(_ level: Double) -> Int { Int((min(max(level, 0), 1) * 100).rounded()) }

    /// Asks for the permission app volumes need, in the card's first row.
    private var permission: some View {
        HStack(spacing: Deck.Metric.gap) {
            DeckDot(.signal)
            Text("Allow System Audio Recording to change app volumes")
                .deckText(.detail).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Button("Open Settings") { NSWorkspace.shared.open(.privacySettings("Privacy_AudioCapture")) }
                .buttonStyle(.deck(.accent, compact: true))
        }
        .frame(minHeight: 38)
        .accessibilityElement(children: .combine)
    }

    /// What fits in the device list: "AirPods Pro" out of "Niyam's AirPods Pro",
    /// "Speakers" out of "MacBook Pro Speakers", "iPhone Microphone" out of "Niyam's iPhone
    /// Microphone".
    nonisolated static func shortName(_ name: String) -> String {
        if let airPods = name.range(of: "AirPods") { return String(name[airPods.lowerBound...]) }
        if name.hasSuffix("Headphones") { return "Headphones" }
        var name = name
        if let owner = name.range(of: "'s ") ?? name.range(of: "’s ") { name = String(name[owner.upperBound...]) }
        let macs = ["MacBook Pro ", "MacBook Air ", "MacBook ", "iMac ", "Mac mini ", "Mac Studio ", "Mac Pro "]
        if let mac = macs.first(where: { name.hasPrefix($0) }) { name = String(name.dropFirst(mac.count)) }
        return name
    }
}

private struct DeviceRow: View {
    let device: SoundDevice
    let current: Bool
    let selection: Namespace.ID
    let choose: () -> Void

    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Button(action: choose) {
            HStack(spacing: 5) {
                Image(systemName: device.symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 15)
                Text(SoundView.shortName(device.name))
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if current {
                    Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold))
                }
            }
            .foregroundStyle(current ? Deck.text : hovering ? Deck.secondary : Deck.tertiary)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background {
                if current {
                    shape.fill(Deck.control).matchedGeometryEffect(id: "device", in: selection)
                } else if hovering {
                    shape.fill(Deck.cardRaised)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(device.name)
        .accessibilityLabel(device.name)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

extension Mixer {
    /// For the Sound tab's settings: what it does, and a way back to every app's own volume.
    public var settingsView: some View { MixerSettings(mixer: self) }
}

private struct MixerSettings: View {
    let mixer: Mixer

    var body: some View {
        LabeledContent {
            Button("Reset All") { mixer.resetAll() }
                .disabled(mixer.levels.isEmpty && mixer.muted.isEmpty)
        } label: {
            Text("App volumes")
            Text(
                "Turn each app up, down, or off in the Sound tab. It needs the system audio permission, "
                    + "and nothing is recorded.")
        }
    }
}
