// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckCore
import TopdeckFeatures
import TopdeckSurface

/// The Mac space's body, as the board: the performance cards and processes on the left; on the right the
/// output volume and display brightness, then Sound, Displays, Network, Storage and System. A row slides
/// its screen over the whole body (the deck's back button brings the page back), so everything those
/// screens do stays where it was. A part is left out when its feature is off.
public struct MacScreen: View {
    let performance: PerformanceFeature?
    let mixer: Mixer?
    let monitors: MonitorsFeature?
    let enabled: Set<FeatureID>
    /// The existing screen of a Mac feature.
    let detail: (FeatureID) -> AnyView

    @Environment(\.deckDetail) private var open
    @Environment(\.openDeckDetail) private var openDetail
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        performance: PerformanceFeature?, mixer: Mixer?, monitors: MonitorsFeature?, enabled: Set<FeatureID>,
        detail: @escaping (FeatureID) -> AnyView
    ) {
        self.performance = performance
        self.mixer = mixer
        self.monitors = monitors
        self.enabled = enabled
        self.detail = detail
    }

    public var body: some View {
        ZStack {
            if let open, SpaceID.mac.details.contains(open) {
                detail(open)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            } else {
                page.transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: open)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    private var page: some View {
        HStack(spacing: Deck.Metric.gap) {
            if let performance {
                PerformanceView(performance: performance)
                Rectangle().fill(Deck.hairline).frame(width: 1)
            }
            side.frame(width: performance == nil ? nil : 156)
        }
    }

    // MARK: The right column

    private var side: some View {
        VStack(spacing: 0) {
            if let mixer { VolumeRow(mixer: mixer) }
            if let monitors, enabled.contains(.monitors), let brightness = monitors.brightness {
                BrightnessRow(level: brightness) { monitors.setBrightness($0) }
            }
            DeckSeparator().padding(.vertical, 8)
            ForEach(SpaceID.mac.details.filter(enabled.contains), id: \.self) { feature in
                Button {
                    openDetail(feature)
                } label: {
                    HStack {
                        Text(SpaceID.mac.detailTitle(feature)).deckText(.body, color: Deck.secondary)
                        Spacer(minLength: 0)
                        DeckIconView(.chevronRight, size: 12).foregroundStyle(Deck.tertiary)
                    }
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(SpaceID.mac.detailTitle(feature))
            }
            Spacer(minLength: 0)
        }
    }
}

/// The output volume: its icon (a click mutes) and a slider. Dimmed when the output has no volume of its own.
private struct VolumeRow: View {
    let mixer: Mixer

    var body: some View {
        let output = mixer.output
        let level = output.map { $0.isMuted ? 0 : $0.level } ?? 0
        SideLevel(
            icon: .volume, tint: Deck.Accent.now, level: level, label: "Output volume",
            enabled: output?.hasVolume == true, set: { mixer.setDeviceLevel($0, for: .output) },
            toggle: { mixer.toggleDeviceMute(.output) }
        )
        .onAppear { mixer.appeared() }
        .onDisappear { mixer.disappeared() }
    }
}

private struct BrightnessRow: View {
    let level: Double
    let set: (Double) -> Void

    var body: some View {
        SideLevel(
            icon: .sun, tint: Deck.Tint.yellow, level: level, label: "Display brightness", enabled: true, set: set)
    }
}

/// A 30 point row: a tinted icon and a slider in that tint.
private struct SideLevel: View {
    let icon: DeckIcon
    let tint: Color
    let level: Double
    let label: String
    let enabled: Bool
    let set: (Double) -> Void
    var toggle: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                toggle?()
            } label: {
                DeckIconView(icon, size: 13)
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.tint(0.2)))
            }
            .buttonStyle(.plain)
            .disabled(toggle == nil)
            .accessibilityHidden(toggle == nil)
            .accessibilityLabel(toggle == nil ? "" : "Mute")
            DeckSlider(level, label: label, enabled: enabled, set: set)
                .environment(\.deckAccent, tint)
        }
        .frame(height: 30)
    }
}
