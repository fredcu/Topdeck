// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import Testing

@testable import TopdeckFeatures

/// Renders each feature tab with sample data inside a notch-sized black panel. Always checks that
/// it draws; with SNAPSHOT_DIR set, also writes PNGs there for eyeballing.
@MainActor
struct FeatureSnapshotTests {
    /// The content area of an expanded notch.
    private let size = CGSize(width: 428, height: 200)
    /// The content area of the smallest open notch.
    private static let smallest = CGSize(width: 350, height: 102)

    @Test func shelfWithFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ShelfSnapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = try ["Invoice.pdf", "Screenshot.png", "Notes.txt", "Archive.zip"].map { name in
            let url = folder.appending(path: name)
            try Data(name.utf8).write(to: url)
            return url
        }
        let shelf = ShelfFeature(storeURL: folder.appending(path: "shelf.json"))
        shelf.add(files)
        try FileManager.default.removeItem(at: files[3])
        shelf.phase = .foreground  // Archive.zip now shows as missing
        try render(shelf.view, name: "shelf")
    }

    @Test func clipboardOffThenWithAHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClipboardSnapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard(name: .init("ClipboardSnapshot.\(UUID().uuidString)"))
        let clipboard = ClipboardFeature(
            pasteboard: pasteboard, defaults: UserDefaults(suiteName: "CS-\(UUID())")!,
            storeURL: folder.appending(path: "clipboard.json"), imagesURL: folder.appending(path: "Clipboard"),
            frontmostApp: { ("com.apple.Safari", "Safari") })
        clipboard.phase = .foreground
        try render(clipboard.view, name: "clipboard-off")
        clipboard.startRecording()
        for text in ["Meeting at 4 in the big room", "https://github.com/fredcu/Topdeck", "make install"] {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            clipboard.check()
        }
        clipboard.toggleFavorite(try #require(clipboard.items.last))
        try render(clipboard.view, name: "clipboard")
    }

    /// The tab as the notch shows it: white on black, dark mode, in the content area.
    private func inNotch(_ view: some View, size: CGSize) -> some View {
        view
            .frame(width: size.width, height: size.height)
            .padding(16)
            .background(.black)
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
    }

    @Test func timerPresetsAndARunningCountdown() throws {
        let timer = TimerFeature()
        try render(timer.view, name: "timer-presets")
        timer.start(25 * 60)
        try render(timer.view, name: "timer-running")
        timer.mode = .stopwatch
        timer.toggleStopwatch(now: Date(timeIntervalSinceNow: -83.4))
        timer.lap(now: Date(timeIntervalSinceNow: -41))
        try render(timer.view, name: "stopwatch")
    }

    @Test func keepAwakeOffTimedAndUntilTurnedOff() throws {
        let timer = TimerFeature()
        timer.mode = .keepAwake
        try render(timer.view, name: "keep-awake")
        timer.keepAwake(for: 2 * 3600)
        try render(timer.view, name: "keep-awake-timed")
        timer.keepAwake(for: nil)
        try render(timer.view, name: "keep-awake-on")
        timer.allowSleep()
    }

    /// A month of made-up traffic, busiest in the evenings, then a download ramping up over the last
    /// minute; each range of the chart, and the tab with nothing recorded yet.
    @Test func networkLiveAndItsHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "NetworkSnapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var counters = ["en0": Traffic()]
        let network = NetworkFeature(
            defaults: UserDefaults(suiteName: "NS-\(UUID())")!, storeURL: folder.appending(path: "network.sqlite"),
            netSpeedURL: nil, readCounters: { counters })
        network.phase = .foreground
        try render(network.view, name: "network-empty")
        network.phase = .stopped
        let now = Date.now
        for hour in stride(from: 30 * 24, through: 1, by: -1) {
            let evening = max(0, sin(Double(hour % 24) / 24 * .pi * 2 - 1.2))
            let noise = abs(sin(Double(hour) * 12.9898)) * 0.7
            counters["en0"]?.down += Int64(400_000_000 * (evening + noise) + 20_000_000)
            counters["en0"]?.up += Int64(60_000_000 * (evening + noise * 0.5) + 5_000_000)
            network.receive(counters, at: now - TimeInterval(hour * 3600) - 61)
        }
        for second in stride(from: 60, through: 0, by: -1) {
            let ramp = min(1, Double(60 - second) / 25)
            counters["en0"]?.down += Int64(24_000_000 * ramp * (0.85 + 0.15 * sin(Double(second))))
            counters["en0"]?.up += Int64(900_000 + 500_000 * abs(sin(Double(second) / 3)))
            network.receive(counters, at: now - TimeInterval(second))
        }
        network.phase = .foreground
        for range in HistoryRange.allCases {
            network.range = range
            try render(network.view, name: range == .day ? "network" : "network-\(range.rawValue)", settles: true)
        }
        network.phase = .stopped
    }

    /// One monitor with both controls, one without speakers, one that doesn't answer DDC; then none.
    @Test func monitorsWithAndWithoutDDC() async throws {
        let channels: [CGDirectDisplayID: any DDCChannel] = [
            1: FakeMonitor([
                .brightness: DDC.Level(current: 70, maximum: 100), .volume: DDC.Level(current: 30, maximum: 100),
            ]),
            2: FakeMonitor([.brightness: DDC.Level(current: 40, maximum: 100)]),
        ]
        final class Displays: @unchecked Sendable {
            var list: [(id: CGDirectDisplayID, name: String)] = [
                (1, "LG UltraFine"), (2, "DELL U2720Q"), (3, "Projector"),
            ]
        }
        let displays = Displays()
        let monitors = MonitorsFeature(
            backend: .init(
                displays: { displays.list }, channels: { ids in channels.filter { ids.contains($0.key) } },
                perform: { $0() }, send: { $0() }, sleepDisplays: { true }))
        monitors.phase = .foreground
        #expect(await eventually { monitors.monitors.allSatisfy { $0.status != .checking } })
        try render(monitors.view, name: "monitors")
        displays.list = []
        monitors.refresh()
        #expect(await eventually { monitors.monitors.isEmpty && monitors.hasLooked })
        try render(monitors.view, name: "monitors-none")
        monitors.phase = .stopped
    }

    @Test func shortcutsWhileLoading() throws {
        try render(ShortcutsFeature().view, name: "shortcuts-loading")
    }

    /// Without a size, at the default size and again at the smallest, where every tab is tightest.
    /// `settles` draws it once what rises into place on appearing has (without animation, so at once).
    private func render(_ view: some View, name: String, size: CGSize? = nil, settles: Bool = false) throws {
        guard let size else {
            try render(view, name: name, size: self.size, settles: settles)
            return try render(view, name: name + "-smallest", size: Self.smallest, settles: settles)
        }
        let host = NSHostingView(rootView: inNotch(view, size: size).transaction { if settles { $0.animation = nil } })
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: size.width + 32, height: size.height + 32),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        if settles {
            RunLoop.main.run(until: .now + 0.1)
            host.layoutSubtreeIfNeeded()
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        if let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(filePath: directory).appending(path: "\(name).png"))
        }
    }
}
