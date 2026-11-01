// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckCore
import TopdeckFeatures
import TopdeckSurface

/// The Mac space's body, as the board: the thermal strip and the performance tiles on the left; on the right
/// one card with the output volume and display brightness, then one list of Sound, Displays, Network, Storage
/// and System, each with its current value (System: what needs a look, else the busiest process). A row slides
/// its screen over the whole body (the deck's back button brings the page back), so everything those screens do
/// stays where it was. A part is left out when its feature is off, except System, which is there whenever
/// Performance is. The page has no second row of its own: pin and Settings stand above the right column.
public struct MacScreen: View {
    let performance: PerformanceFeature?
    let mixer: Mixer?
    let monitors: MonitorsFeature?
    let admin: SystemAdminFeature?
    let enabled: Set<FeatureID>
    /// The existing screen of a Mac feature.
    let detail: (FeatureID) -> AnyView

    @Environment(\.deckDetail) private var open
    @Environment(\.openDeckDetail) private var openDetail
    @Environment(\.deckCornerInset) private var cornerInset
    @Environment(\.deckAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        performance: PerformanceFeature?, mixer: Mixer?, monitors: MonitorsFeature?, admin: SystemAdminFeature?,
        enabled: Set<FeatureID>, detail: @escaping (FeatureID) -> AnyView
    ) {
        self.performance = performance
        self.mixer = mixer
        self.monitors = monitors
        self.admin = admin
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
        GeometryReader { space in
            HStack(spacing: Deck.Metric.gap) {
                if let performance {
                    PerformanceView(performance: performance)
                }
                side.frame(width: performance == nil ? nil : (space.size.width < 560 ? 176 : 192))
            }
        }
    }

    // MARK: The right column

    private var side: some View {
        VStack(spacing: Deck.Metric.gap) {
            sliders
            list
        }
        .padding(.top, cornerInset)
    }

    /// Volume and brightness in one card, 40 high each, a hairline between.
    @ViewBuilder private var sliders: some View {
        let brightness = enabled.contains(.monitors) ? monitors?.brightness : nil
        if mixer != nil || brightness != nil {
            VStack(spacing: 0) {
                if let mixer { VolumeRow(mixer: mixer) }
                if mixer != nil, brightness != nil { Rectangle().fill(Deck.hairline).frame(height: 1) }
                if let monitors, let brightness { BrightnessRow(level: brightness) { monitors.setBrightness($0) } }
            }
            .modifier(MacCard())
        }
    }

    /// The screens that slide over the page, in one card sharing its height, each with where things stand.
    private var list: some View {
        let features = SpaceID.mac.openableDetails(enabled: enabled)
        return VStack(spacing: 0) {
            ForEach(Array(features.enumerated()), id: \.element) { index, feature in
                if index > 0 { Rectangle().fill(Deck.hairline).frame(height: 1) }
                row(feature)
            }
        }
        .modifier(MacCard())
        .frame(maxHeight: .infinity)
    }

    private func row(_ feature: FeatureID) -> some View {
        let title = SpaceID.mac.detailTitle(feature)
        let value = value(of: feature)
        let color: Color =
            switch value.tone {
            case .stop: Deck.stop
            case .accent: accent
            case .quiet: Deck.tertiary
            }
        return Button {
            openDetail(feature)
        } label: {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).layoutPriority(1)
                Text(value.text).font(.system(size: 12)).foregroundStyle(color).lineLimit(1)
                    .truncationMode(.tail).frame(maxWidth: .infinity, alignment: .trailing)
                DeckIconView(.chevronRight, size: 10).foregroundStyle(Deck.tertiary)
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value.text)
    }

    /// Where the screen's subject stands now.
    private func value(of feature: FeatureID) -> MacRows.Summary {
        let text: String =
            switch feature {
            case .sound: mixer?.output?.name ?? ""
            case .monitors: "\(NSScreen.screens.count)"
            case .network: performance?.networkName ?? ""
            case .storage: "Clean up"
            default: ""
            }
        guard feature == .admin else { return MacRows.Summary(text: text) }
        // Only what the features already know: the admin lists are read while its screen is open.
        return MacRows.systemSummary(
            failed: admin?.failedCount ?? 0, updates: admin?.outdated.count ?? 0, busiest: performance?.busiestProcess)
    }
}

/// Words on the page's rows, as pure functions.
enum MacRows {
    /// A row's words and how they are coloured.
    struct Summary: Equatable {
        enum Tone { case stop, accent, quiet }

        var text: String
        var tone = Tone.quiet
    }

    /// The System row: launch services that failed ("1 failed", in stop), else Homebrew packages with updates
    /// ("3 updates", in the accent), else the busiest process ("Xcode  48%"); empty when none is known.
    static func systemSummary(failed: Int, updates: Int, busiest: (name: String, cpu: Double)?) -> Summary {
        if failed > 0 { return Summary(text: "\(failed) failed", tone: .stop) }
        if updates > 0 { return Summary(text: "\(updates) \(updates == 1 ? "update" : "updates")", tone: .accent) }
        guard let busiest else { return Summary(text: "") }
        return Summary(text: "\(busiest.name)  \(Int(busiest.cpu.rounded()))%")
    }
}

/// A card of the page's right column: the card colour, a hairline outline, clipped to the radius.
private struct MacCard: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Deck.Radius.tile + 2, style: .continuous)
        content
            .background(shape.fill(Deck.card))
            .overlay(shape.strokeBorder(Deck.hairline, lineWidth: 1))
            .clipShape(shape)
    }
}

/// The output volume: its icon (a click mutes) and a slider. Dimmed when the output has no volume of its own.
private struct VolumeRow: View {
    let mixer: Mixer

    var body: some View {
        let output = mixer.output
        let level = output.map { $0.isMuted ? 0 : $0.level } ?? 0
        SideLevel(
            icon: .volume, tint: Deck.text, level: level, label: "Output volume",
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

/// A 40 point row: an icon, a slider in `tint`, and the percent.
private struct SideLevel: View {
    let icon: DeckIcon
    let tint: Color
    let level: Double
    let label: String
    let enabled: Bool
    let set: (Double) -> Void
    var toggle: (() -> Void)?

    var body: some View {
        HStack(spacing: 9) {
            Button {
                toggle?()
            } label: {
                DeckIconView(icon, size: 16).foregroundStyle(Deck.secondary).frame(width: 18, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(toggle == nil)
            .accessibilityHidden(toggle == nil)
            .accessibilityLabel(toggle == nil ? "" : "Mute")
            DeckSlider(level, label: label, enabled: enabled, set: set)
                .environment(\.deckAccent, tint)
            Text("\(Int((min(max(level, 0), 1) * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Deck.secondary)
                .frame(width: 34, alignment: .trailing).accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }
}
