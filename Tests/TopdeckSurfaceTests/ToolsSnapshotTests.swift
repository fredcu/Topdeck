// SPDX-License-Identifier: MIT
import AppKit
import ImageIO
import SwiftUI
import Testing
import TopdeckCore

@testable import TopdeckFeatures
@testable import TopdeckSurface

/// Tools in the real deck, with sample data, idle at the default and the smallest size and running; and the
/// closed notch of a meeting about to start. With SNAPSHOT_DIR set, also writes PNGs there.
@MainActor
struct ToolsSnapshotTests {
    private static let metrics = NotchMetrics(
        screen: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
        left: CGRect(x: 0, y: 950, width: 662, height: 32), right: CGRect(x: 850, y: 950, width: 662, height: 32))

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "PlanTools.\(UUID().uuidString)")! }

    /// A folder of captures with sample pictures: seven screenshots and a GIF, the newest first.
    private func captures() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ToolsSnapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let shades: [(String, UInt32, UInt32)] = [
            ("a.png", 0x2B4C7E, 0x6B4FA0), ("b.gif", 0x3B4660, 0x2E6CB8), ("c.png", 0xB5562B, 0xA8325E),
            ("d.png", 0x1E8E7E, 0x3B4660), ("e.png", 0x4B3B60, 0x2E6CB8), ("f.png", 0x7E6B2B, 0x3B4660),
            ("g.png", 0x2B7E5A, 0x6B4FA0), ("h.png", 0x602B3B, 0xB8862E),
        ]
        for (offset, shade) in shades.enumerated() {
            let url = folder.appending(path: shade.0)
            let context = CGContext(
                data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            func color(_ hex: UInt32) -> CGColor {
                CGColor(
                    red: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: 1)
            }
            let gradient = CGGradient(
                colorsSpace: nil, colors: [color(shade.1), color(shade.2)] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 320, y: 200), options: [])
            context.setFillColor(CGColor(gray: 1, alpha: 0.14))
            context.fill(CGRect(x: 20, y: 20, width: 280, height: 160))
            let type = url.pathExtension == "gif" ? "com.compuserve.gif" : "public.png"
            let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            CGImageDestinationFinalize(destination)
            try FileManager.default.setAttributes(
                [.creationDate: Date().addingTimeInterval(-Double(offset) * 3600)], ofItemAtPath: url.path)
        }
        return folder
    }

    /// `running`: the timer counting down, Keep Awake on and System audio chosen.
    private func tools(running: Bool) async throws -> (CaptureFeature, TimerFeature, ShortcutsFeature) {
        let colors = defaults()
        colors.set(["#FFB340", "#3B82F6", "#FC3C44", "#34C759"], forKey: CaptureFeature.colorsKey)
        let timer = TimerFeature(defaults: defaults())
        if running {
            timer.start(1498)
            timer.keepAwake(for: 4320)
        }
        let capture = CaptureFeature(defaults: colors, folder: try captures())
        capture.reloadRecents()
        try await Task.sleep(for: .milliseconds(300))
        #expect(capture.recents.count == 8, "the sample captures are listed")
        for item in capture.recents { _ = await capture.thumbnails.image(for: item, maxPixel: 360) }
        capture.recorder.options.systemAudio = running
        return (capture, timer, ShortcutsFeature(defaults: defaults()))
    }

    private func draw(_ name: String, events: [NotchEvent], size: CGSize, content: NotchContent) throws {
        let preferences = NotchPreferences(defaults: defaults())
        preferences.resizeExpanded(to: size)
        let engine = NotchEngine()
        engine.send(.setSpaces(preferences.spaceSet))
        events.forEach(engine.send)
        let panel = Self.metrics.panelFrame.size
        let view = NotchView(engine: engine, metrics: Self.metrics, preferences: preferences, content: content)
            .frame(width: panel.width, height: panel.height)
            .background(Color(white: 0.82))
            .transaction { $0.animation = nil }  // the timer's digits have rolled into place
        let image = try #require(NotchSnapshotTests.render(view, size: panel, name: name, settle: true))
        #expect(image.pixelsWide > 0)
    }

    private func content(
        screen: @escaping (SpaceID, Set<FeatureID>) -> AnyView?, slot: @escaping (SpaceID) -> AnyView,
        actions: @escaping (SpaceID, FeatureID?) -> AnyView
    ) -> NotchContent {
        NotchContent(
            feature: { _ in AnyView(EmptyView()) }, now: { AnyView(EmptyView()) }, badge: { $0 == .agents ? 2 : 0 },
            actions: actions, dropFiles: { _ in false }, openSettings: {}, screen: screen, slot: slot,
            hasRow: { $0.hasSecondRow(shelfFilled: false, clipboardHistory: false) })
    }

    @Test(arguments: [
        ("R3c-Tools", NotchPreferences.defaultExpandedSize, false),
        ("R3c-Tools-min", NotchPreferences.minimumExpandedSize, false),
        ("R3c-Tools-running", NotchPreferences.defaultExpandedSize, true),
    ])
    func toolsFitItsDeck(name: String, size: CGSize, running: Bool) async throws {
        let (capture, timer, shortcuts) = try await tools(running: running)
        let content = content(
            screen: { space, _ in
                space == .tools
                    ? AnyView(ToolsScreen(capture: capture, timer: timer, shortcuts: shortcuts, sleepDisplays: {}))
                    : nil
            },
            slot: { _ in AnyView(EmptyView()) }, actions: { _, _ in AnyView(EmptyView()) })
        try draw(name, events: [.show, .selectSpace(.tools)], size: size, content: content)
        timer.allowSleep()
    }

    @Test func aMeetingAboutToStartHasAJoinButton() throws {
        let link = URL(string: "https://meet.google.com/abc-defg-hij")!
        let meeting = Activity(
            feature: .calendar, symbol: "video.fill", title: "Design review starts in", duration: .zero,
            countdown: Date(timeIntervalSinceNow: 4 * 60), meetingLink: link)
        let closed = ClosedContent(meeting)
        #expect(closed.join == link && closed.label == nil && closed.trailingTone == .signal)
        let plain = ClosedContent(
            Activity(
                feature: .timer, symbol: "cup.and.saucer.fill", title: "Awake", duration: .zero,
                countdown: Date(timeIntervalSinceNow: 600)))
        #expect(plain.join == nil && closed.trailingWidth > plain.trailingWidth, "room for the button")
        try draw(
            "Closed", events: [.show, .setOngoing(meeting)], size: NotchPreferences.defaultExpandedSize,
            content: content(
                screen: { _, _ in nil }, slot: { _ in AnyView(EmptyView()) },
                actions: { _, _ in AnyView(EmptyView()) }))
    }
}
