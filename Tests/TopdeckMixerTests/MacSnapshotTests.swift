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
    private func sample(
        battery: Bool = true, hot: Bool = false, sensors: Bool = true, gpuSensor: Bool = true
    ) -> PerformanceFeature {
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
                var temperatures = Temperatures(
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
                // A Mac whose sensors do not name the GPU, and no SMC to ask.
                if !gpuSensor { temperatures.gpu = nil }
                snapshot.temperatures = temperatures
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
                ("Xcode", 48.2, 3.1e9), ("Safari", 12.6, 1.4e9), ("WindowServer", 9.8, 0.612e9),
                ("Topdeck", 3.1, 0.188e9), ("Claude", 2.7, 0.54e9), ("Music", 1.9, 0.31e9),
                ("mds_stores", 1.2, 0.096e9), ("Finder", 0.6, 0.142e9), ("Terminal", 0.4, 0.088e9),
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
            performance: sample(), mixer: mixer(), monitors: monitors, admin: nil, enabled: enabled,
            detail: { AnyView(Text(SpaceID.mac.detailTitle($0)).deckText(.body)) })
        try render(screen, name: "R3c-Mac", detail: nil)
        let sound = MacScreen(
            performance: sample(), mixer: mixer(), monitors: monitors, admin: nil, enabled: enabled,
            detail: { _ in AnyView(SoundView(mixer: mixer(), monitors: monitors)) })
        try render(sound, name: "R3c-Mac-Sound", detail: .sound)
        monitors.phase = .stopped
    }

    @Test func aHotMacShowsThrottlingAndTheReadingsThatRunHot() throws {
        let hot = sample(hot: true)
        #expect(hot.snapshot.thermal == .throttling && hot.snapshot.temperatures?.chip == 96)
        let screen = MacScreen(
            performance: hot, mixer: mixer(), monitors: nil, admin: nil, enabled: Set(FeatureID.allCases),
            detail: { _ in AnyView(EmptyView()) })
        try render(screen, name: "R3c-Mac-hot", detail: nil)
    }

    @Test func aMacThatReportsNoTemperaturesShowsOnlyTheState() throws {
        let quiet = sample(sensors: false)
        #expect(quiet.snapshot.temperatures == nil)
        let screen = MacScreen(
            performance: quiet, mixer: mixer(), monitors: nil, admin: nil, enabled: Set(FeatureID.allCases),
            detail: { _ in AnyView(EmptyView()) })
        try render(screen, name: "R3c-Mac-nosensors", detail: nil)
    }

    @Test func aReadingTheMacDoesNotGiveIsLeftOutOfTheStrip() throws {
        let performance = sample(gpuSensor: false)
        #expect(performance.snapshot.temperatures?.gpu == nil && performance.snapshot.temperatures?.chip != nil)
        let screen = MacScreen(
            performance: performance, mixer: mixer(), monitors: nil, admin: nil, enabled: Set(FeatureID.allCases),
            detail: { _ in AnyView(EmptyView()) })
        try render(screen, name: "R3c-Mac-nogpu", detail: nil)
    }

    @Test func theSystemRowPutsWhatNeedsALookBeforeTheBusiestProcess() {
        let xcode = (name: "Xcode", cpu: 48.2)
        #expect(MacRows.systemSummary(failed: 0, updates: 0, busiest: xcode) == .init(text: "Xcode  48%"))
        #expect(
            MacRows.systemSummary(failed: 0, updates: 3, busiest: xcode) == .init(text: "3 updates", tone: .accent))
        #expect(MacRows.systemSummary(failed: 0, updates: 1, busiest: nil) == .init(text: "1 update", tone: .accent))
        #expect(
            MacRows.systemSummary(failed: 2, updates: 3, busiest: xcode) == .init(text: "2 failed", tone: .stop),
            "a failure outranks an update")
        #expect(MacRows.systemSummary(failed: 0, updates: 0, busiest: nil) == .init(text: ""))
        #expect(
            MacRows.systemSummary(failed: 0, updates: 0, busiest: (name: "kernel_task", cpu: 0.4)).text
                == "kernel_task  0%")
    }

    @Test func theRowsFiguresComeFromWhatTheFeaturesAlreadyKnow() {
        let performance = sample()
        #expect(performance.busiestProcess?.name == "Xcode" && performance.busiestProcess?.cpu == 48.2)
        #expect(PerformanceFeature(source: { Sampler() }, interval: 3600).busiestProcess == nil)
        let known = admin(failed: 1, updates: 2)
        #expect(known.failedCount == 1 && known.outdated.count == 2)
        #expect(SystemAdminFeature().failedCount == 0, "nothing is read until its screen is open")
    }

    @Test func theSystemRowShowsFailuresAndUpdates() throws {
        for (name, failed, updates) in [("failed", 2, 3), ("updates", 0, 3)] {
            let screen = MacScreen(
                performance: sample(), mixer: mixer(), monitors: nil, admin: admin(failed: failed, updates: updates),
                enabled: Set(FeatureID.allCases), detail: { _ in AnyView(EmptyView()) })
            try render(screen, name: "R3c-Mac-system-\(name)", detail: nil)
        }
    }

    @Test func theSystemScreenOpensOnTheProcessTable() throws {
        let performance = sample()
        for (name, part, failed) in [("", SystemScreen.Part.processes, 0), ("-services", .services, 2)] {
            let admin = admin(failed: failed, updates: 3)
            let screen = MacScreen(
                performance: performance, mixer: mixer(), monitors: nil, admin: admin,
                enabled: Set(FeatureID.allCases),
                detail: { _ in
                    AnyView(SystemScreen(performance: performance, admin: admin, icon: icon, part: part))
                })
            try render(screen, name: "R3c-System\(name)", detail: .admin)
        }
    }

    @Test func withSystemAdminOffTheSystemScreenIsTheProcessTableAlone() throws {
        let performance = sample()
        let screen = MacScreen(
            performance: performance, mixer: mixer(), monitors: nil, admin: nil,
            enabled: Set(FeatureID.allCases).subtracting([.admin]),
            detail: { _ in AnyView(SystemScreen(performance: performance, admin: nil, icon: icon, part: .processes)) })
        // The deck's own settings leave System Admin off, as they do on a fresh install.
        try render(screen, name: "R3c-System-noadmin", detail: .admin)
    }

    private func admin(failed: Int, updates: Int) -> SystemAdminFeature {
        let admin = SystemAdminFeature()
        let services = (0..<5).map { index in
            LaunchItem(
                label: "com.example.agent\(index)",
                plist: URL(filePath: "/Users/me/Library/LaunchAgents/a\(index).plist"), scope: .user,
                domain: "gui/501", state: index < failed ? .failed : (index == 4 ? .loaded : .running),
                pid: index < failed || index == 4 ? nil : 400 + index)
        }
        let packages = (0..<6).map { index in
            BrewPackage(
                name: ["wget", "node", "git", "ffmpeg", "jq", "ripgrep"][index], kind: .formula,
                version: "1.\(index).0", latest: index < updates ? "1.\(index).1" : nil)
        }
        admin.preview(services: services, packages: packages)
        return admin
    }

    /// Stand-ins for app icons: a coloured tile for most, none for the system's own processes.
    private func icon(_ pid: Int32) -> NSImage? {
        let colors: [Int32: NSColor] = [
            1: .systemBlue, 2: .systemCyan, 4: .systemOrange, 5: .systemBrown, 6: .systemRed, 8: .systemTeal,
            9: .lightGray,
        ]
        guard let color = colors[pid] else { return nil }
        return NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            return true
        }
    }

    @Test func aMacWithoutABatteryShowsItsUptime() throws {
        let screen = MacScreen(
            performance: sample(battery: false), mixer: nil, monitors: nil, admin: nil,
            enabled: [.performance, .storage],
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
