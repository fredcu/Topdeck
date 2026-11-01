// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import Testing
import TopdeckCore

@testable import TopdeckFeatures
@testable import TopdeckMixer
@testable import TopdeckSurface

/// The Mac space in the real deck (no second row of its own, pin and Settings above the right column) with
/// sample readings, at the default and the smallest open size, hot, without sensors, and one of the screens that
/// slide over it. With SNAPSHOT_DIR set, also writes 2x PNGs there.
@MainActor
struct MacSnapshotTests {
    private static let sizes = [("", CGSize(width: 700, height: 430)), ("-620x340", CGSize(width: 620, height: 340))]
    private static let metrics = NotchMetrics(
        screen: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
        left: CGRect(x: 0, y: 950, width: 662, height: 32), right: CGRect(x: 850, y: 950, width: 662, height: 32))

    /// A reading like the board's: a quiet Mac with a battery, and a minute of history that moves a little.
    /// `hot` is a Mac that is slowing down; `sensors` false one that reports no temperatures.
    private func sample(battery: Bool = true, hot: Bool = false, sensors: Bool = true) -> PerformanceFeature {
        func reading(_ step: Int) -> PerformanceFeature.Snapshot {
            var snapshot = PerformanceFeature.Snapshot()
            let wave = Double((step * 37) % 11)
            snapshot.efficiencyCores = [12 + wave, 14 + wave]
            snapshot.performanceCores = [20 + wave, 22 + wave, 18, 16]
            snapshot.gpu = 22 + wave / 2
            snapshot.memory = MemorySample(active: 12e9, wired: 4e9, compressed: 3.4e9, total: 32 * 1_073_741_824)
            snapshot.diskRead = 81_000 + wave * 5000
            snapshot.diskWritten = 1_014_000 - wave * 20000
            snapshot.diskFree = 156_000_000_000
            snapshot.diskTotal = 460_000_000_000
            snapshot.network = Rate(down: 2_800 + wave * 700, up: 300 + wave * 40)
            if sensors {
                snapshot.temperatures = Temperatures(
                    from: hot
                        ? [
                            (name: "PMU tdie1", value: 88), (name: "PMU tdie2", value: 104),
                            (name: "GPU MTR Temp Sensor", value: 88), (name: "NAND CH0 temp", value: 52),
                            (name: "gas gauge battery", value: 39),
                        ]
                        : [
                            (name: "PMU tdie1", value: 35), (name: "PMU tdie2", value: 61),
                            (name: "GPU MTR Temp Sensor", value: 41), (name: "NAND CH0 temp", value: 38),
                            (name: "gas gauge battery", value: 34),
                        ])
            }
            snapshot.thermal = hot ? .throttling : .normal
            snapshot.loadAverage = 1.42
            snapshot.chipName = "M5"
            snapshot.networkInterface = "Wi-Fi"
            if battery {
                var report = BatteryReport()
                report.percent = 80
                report.designCapacity = 6000
                report.currentCapacity = 6000
                report.minutesToEmpty = 222
                snapshot.battery = report
            }
            let apps: [(String, Double, Double)] = [
                ("ChatGPT", 1.4, 2.5e9), ("Claude", 0.2, 2.1e9), ("Xcode", 0.9, 1.3e9), ("Safari", 0.6, 0.98e9),
                ("Slack", 0.4, 0.9e9), ("Finder", 0.1, 0.5e9), ("Mail", 0.1, 0.4e9),
            ]
            let usage = apps.enumerated().map {
                ProcessUsage(pid: Int32($0.offset + 1), cpu: $0.element.1, memory: $0.element.2, name: $0.element.0)
            }
            snapshot.topCPU = usage
            snapshot.topMemory = usage.sorted { $0.memory > $1.memory }
            return snapshot
        }
        let performance = PerformanceFeature(source: { Sampler() }, interval: 3600)
        performance.preview((0..<60).map(reading))
        return performance
    }

    private func mixer() -> Mixer {
        let mixer = Mixer(defaults: UserDefaults(suiteName: "MacSnapshot-\(UUID())")!, live: false)
        let speakers = DeviceLevel(
            id: 72, name: "MacBook Pro Speakers", level: 0.64, isMuted: false, hasVolume: true, symbol: nil)
        mixer.preview(
            apps: [], output: speakers,
            outputs: [SoundDevice(id: 72, name: "MacBook Pro Speakers", symbol: "speaker.wave.2.fill")])
        return mixer
    }

    private struct Panel: DDCChannel {
        func read(_ control: DDC.Control) -> DDC.Level? {
            control == .brightness ? DDC.Level(current: 80, maximum: 100) : nil
        }

        func write(_ control: DDC.Control, value: UInt16) -> Bool { true }
    }

    private func monitors() async throws -> MonitorsFeature {
        let monitors = MonitorsFeature(
            backend: .init(
                displays: { [(1, "Dell U2720Q")] }, channels: { ids in ids.contains(1) ? [1: Panel()] : [:] },
                perform: { $0() }, send: { $0() }, sleepDisplays: { true }))
        monitors.phase = .foreground
        for _ in 0..<200 where monitors.brightness == nil { try await Task.sleep(for: .milliseconds(20)) }
        return monitors
    }

    @Test func theMacPageAndTheScreenThatSlidesOverIt() async throws {
        let monitors = try await monitors()
        #expect(monitors.brightness == 0.8)
        let enabled = Set(FeatureID.allCases)
        let screen = MacScreen(
            performance: sample(), mixer: mixer(), monitors: monitors, enabled: enabled,
            detail: { AnyView(Text(SpaceID.mac.detailTitle($0)).deckText(.body)) })
        try render(screen, name: "R3c-Mac", detail: nil)
        let sound = MacScreen(
            performance: sample(), mixer: mixer(), monitors: monitors, enabled: enabled,
            detail: { _ in AnyView(SoundView(mixer: mixer(), monitors: monitors)) })
        try render(sound, name: "R3c-Mac-Sound", detail: .sound)
        monitors.phase = .stopped
    }

    @Test func aHotMacShowsThrottlingAndTheReadingsThatRunHot() throws {
        let hot = sample(hot: true)
        #expect(hot.snapshot.thermal == .throttling && hot.snapshot.temperatures?.chip == 96)
        let screen = MacScreen(
            performance: hot, mixer: mixer(), monitors: nil, enabled: Set(FeatureID.allCases),
            detail: { _ in AnyView(EmptyView()) })
        try render(screen, name: "R3c-Mac-hot", detail: nil)
    }

    @Test func aMacThatReportsNoTemperaturesShowsOnlyTheState() throws {
        let quiet = sample(sensors: false)
        #expect(quiet.snapshot.temperatures == nil)
        let screen = MacScreen(
            performance: quiet, mixer: mixer(), monitors: nil, enabled: Set(FeatureID.allCases),
            detail: { _ in AnyView(EmptyView()) })
        try render(screen, name: "R3c-Mac-nosensors", detail: nil)
    }

    @Test func theSystemRowNamesTheVersion() {
        #expect(
            MacRows.systemName(OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0))
                == "macOS 27.2")
        #expect(
            MacRows.systemName(OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 1))
                == "macOS 15.6.1")
    }

    @Test func aMacWithoutABatteryShowsItsUptime() throws {
        let screen = MacScreen(
            performance: sample(battery: false), mixer: nil, monitors: nil, enabled: [.performance, .storage],
            detail: { _ in AnyView(EmptyView()) })
        try render(screen, name: "R3c-Mac-nobattery", detail: nil)
    }

    private func render(_ screen: some View, name: String, detail: FeatureID?) throws {
        for (suffix, size) in Self.sizes {
            // The deck's own view, so the navigation, the row (or its absence) and the corner buttons are the real ones.
            let preferences = NotchPreferences(defaults: UserDefaults(suiteName: "MacSnapshot-\(UUID())")!)
            preferences.resizeExpanded(to: size)
            let engine = NotchEngine()
            engine.send(.setSpaces(preferences.spaceSet))
            engine.send(.show)
            engine.send(.selectSpace(.mac))
            if let detail { engine.send(.openDetail(detail)) }
            let content = NotchContent(
                feature: { _ in AnyView(EmptyView()) }, now: { AnyView(EmptyView()) }, badge: { $0 == .agents ? 1 : 0 },
                dropFiles: { _ in false }, openSettings: {}, screen: { _, _ in AnyView(screen) },
                hasRow: { $0.hasSecondRow(shelfFilled: false, clipboardHistory: false) })
            let deck = DeckView(
                engine: engine, metrics: Self.metrics, preferences: preferences, content: content, space: .mac,
                pinned: false
            )
            .frame(width: size.width, height: size.height)
            .background(Deck.panelFill(height: size.height, notch: Self.metrics.topRowHeight))
            .environment(\.colorScheme, .dark)
            .transaction { $0.animation = nil }
            let host = NSHostingView(rootView: deck)
            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
                defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: .now + 0.2)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0)
            if let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(filePath: directory).appending(path: "\(name)\(suffix).png"))
            }
        }
    }
}
