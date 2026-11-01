// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import Testing
import TopdeckCore

@testable import TopdeckSurface

/// Renders the notch offscreen in every state. Always checks that each state draws; with
/// SNAPSHOT_DIR set, also writes PNGs there for eyeballing:
///
///     SNAPSHOT_DIR=/tmp/notch swift test --filter Snapshot
private let notched = NotchMetrics(
    screen: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
    left: CGRect(x: 0, y: 950, width: 662, height: 32), right: CGRect(x: 850, y: 950, width: 662, height: 32))
private let notchless = NotchMetrics(
    screen: CGRect(x: 0, y: 0, width: 2560, height: 1440), safeAreaTop: 0, left: nil, right: nil)
private let standIn = NotchMetrics(
    screen: CGRect(x: 0, y: 0, width: 2560, height: 1440), safeAreaTop: 0, left: nil, right: nil,
    standIn: CGSize(width: 185, height: 24))
private let song = Activity(feature: .media, symbol: "music.note", title: "Midnight City", duration: .seconds(3))
private let volume = Activity(
    feature: nil, symbol: "speaker.wave.2.fill", title: "56%", level: 0.56, duration: .seconds(1))
private let meeting = Activity(
    feature: .calendar, symbol: "video.fill", title: "Standup", duration: .zero,
    countdown: Date(timeIntervalSinceNow: 272))
private let copied = Activity(
    feature: .clipboard, symbol: "doc.on.clipboard.fill", title: "Copied", duration: .seconds(2))
private let waiting = Activity(feature: .agents, symbol: "hand.raised.fill", title: "2 waiting", duration: .zero)
private let downloading = Activity(
    feature: .network, symbol: "arrow.down.circle.fill", title: "24 MB/s", duration: .zero)
private let downloaded = Activity(
    feature: .network, symbol: "checkmark.circle.fill", title: "Downloaded 1.2 GB", duration: .seconds(3))
/// A small red square, as an encoded cover.
private let coverArt: Data = {
    let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
        NSColor(red: 0.7, green: 0.23, blue: 0.28, alpha: 1).setFill()
        rect.fill()
        return true
    }
    return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
}()
private let playing = Activity(
    feature: .media, symbol: "music.note", title: "Midnight City", duration: .seconds(3), artwork: coverArt)
private let timer = Activity(
    feature: .timer, symbol: "timer", title: "Focus", duration: .zero, countdown: Date(timeIntervalSinceNow: 1498))
private let finished = Activity(
    feature: .agents, symbol: "checkmark.circle.fill", title: "Build", duration: .seconds(3))
private let oneWaiting = Activity(feature: .agents, symbol: "hand.raised.fill", title: "Topdeck", duration: .zero)

private func recording(_ phase: RecordingPhase) -> Activity {
    Activity(feature: .capture, symbol: "record.circle", title: "Recording", duration: .seconds(1), recording: phase)
}

private let snapshotCases: [(name: String, metrics: NotchMetrics, events: [NotchEvent])] = [
    ("compact", notched, [.show]),
    ("hover", notched, [.show, .pointerEntered]),
    ("activity", notched, [.show, .activity(song)]),
    ("copied", notched, [.show, .activity(copied)]),
    ("volume", notched, [.show, .activity(volume)]),
    ("ongoing", notched, [.show, .setOngoing(meeting)]),
    ("ongoing-words", notched, [.show, .setOngoing(waiting)]),
    ("ongoing-hover", notched, [.show, .setOngoing(waiting), .pointerEntered]),
    ("ongoing-speed", notched, [.show, .setOngoing(downloading)]),
    ("downloaded", notched, [.show, .activity(downloaded)]),
    ("pill-speed", notchless, [.show, .setOngoing(downloading)]),
    ("pill-activity", notchless, [.show, .activity(copied)]),
    ("pill-ongoing", notchless, [.show, .setOngoing(meeting)]),
    ("expanded-media", notched, [.show, .clicked]),
    ("pinned-notes", notched, [.show, .showFeature(.notes), .togglePin]),
    ("expanded-mac", notched, [.show, .showFeature(.sound)]),
    ("expanded-tools", notched, [.show, .selectSpace(.tools)]),
    ("pill-compact", notchless, [.show]),
    ("pill-expanded", notchless, [.show, .showFeature(.shelf)]),
    ("standin-compact", standIn, [.show]),
    ("standin-activity", standIn, [.show, .activity(song)]),
    ("standin-expanded", standIn, [.show, .showFeature(.shelf)]),
    ("closed-playing", notched, [.show, .setOngoing(playing)]),
    ("closed-timer", notched, [.show, .setOngoing(timer)]),
    ("closed-waiting-one", notched, [.show, .setOngoing(oneWaiting)]),
    ("closed-finished", notched, [.show, .activity(finished)]),
    ("closed-recording-countdown", notched, [.show, .setOngoing(recording(.countdown(3)))]),
    ("closed-recording", notched, [.show, .setOngoing(recording(.running(since: .now - 102)))]),
    ("closed-recording-hover", notched, [.show, .setOngoing(recording(.running(since: .now - 102))), .pointerEntered]),
    ("closed-recording-paused", notched, [.show, .setOngoing(recording(.paused(elapsed: 102)))]),
    ("pill-recording", notchless, [.show, .setOngoing(recording(.running(since: .now - 3725)))]),
    ("closed-drop", notched, [.show, .dragEntered]),
    ("pill-drop", notchless, [.show, .dragEntered]),
]

@MainActor
struct NotchSnapshotTests {
    @Test(arguments: snapshotCases.indices)
    func everyStateRenders(index: Int) throws {
        let (name, metrics, events) = snapshotCases[index]
        try draw(name, metrics: metrics, events: events, preferences: Self.preferences())
    }

    @Test func theTestCoverIsARealImage() {
        let bitmap = NSBitmapImageRep(data: coverArt)
        #expect(bitmap?.colorAt(x: 4, y: 4)?.alphaComponent == 1, "opaque red, not transparent")
    }

    @Test func draggingTheCornerGrowsTheDeckFromItsCenter() {
        let start = NotchPreferences.defaultExpandedSize
        #expect(DeckView.resized(start, by: CGSize(width: 10, height: 5)) == CGSize(width: 720, height: 435))
        #expect(DeckView.resized(start, by: CGSize(width: -3.3, height: 0.4)) == CGSize(width: 693, height: 430))
        let preferences = Self.preferences()
        preferences.resizeExpanded(to: DeckView.resized(start, by: CGSize(width: 900, height: -900)))
        #expect(preferences.expandedSize == CGSize(width: 900, height: 340), "held between the largest and smallest")
    }

    /// The densest layout: every space, its sub-tabs, the pin and Settings, and the resize corner, at
    /// the smallest open size, with the Agents badge.
    @Test(arguments: [notched, notchless, standIn])
    func everySpaceFitsTheSmallestSize(metrics: NotchMetrics) throws {
        let preferences = Self.preferences()
        for feature in FeatureID.allCases { preferences.setEnabled(feature, true) }
        preferences.resizeExpanded(to: NotchPreferences.minimumExpandedSize)
        for space in SpaceID.allCases {
            try draw(
                "smallest-\(space.rawValue)-\(metrics.notch == nil ? "pill" : metrics.notch?.height == 24 ? "standin" : "notch")",
                metrics: metrics, events: [.show, .selectSpace(space)], preferences: preferences, badge: 12)
        }
    }

    /// With spaces hidden or empty, the wings split what's left.
    @Test func hiddenSpacesLeaveTheWingsBalanced() throws {
        let preferences = Self.preferences()
        preferences.setSpace(.tools, hidden: true)
        preferences.setSpace(.agents, hidden: true)
        try draw("wings-four", metrics: notched, events: [.show, .clicked], preferences: preferences, badge: 1)
    }

    /// A closed activity's pieces stay in their wings, clear of the camera housing, whether or not there is
    /// anything on the right: an empty right wing once slid "Awake" 18 points under the camera.
    @Test(arguments: [
        notched,
        // A 14" MacBook Pro at More Space: a 208-point camera.
        NotchMetrics(
            screen: CGRect(x: 0, y: 0, width: 1710, height: 1112), safeAreaTop: 37.5,
            left: CGRect(x: 0, y: 1074.5, width: 751, height: 37.5),
            right: CGRect(x: 959, y: 1074.5, width: 751, height: 37.5)),
    ])
    func closedPiecesStayClearOfTheCamera(metrics: NotchMetrics) throws {
        let awake = Activity(feature: .timer, symbol: "cup.and.saucer.fill", title: "Awake", duration: .zero)
        let volume = Activity(
            feature: nil, symbol: "speaker.wave.2.fill", title: "50%", level: 0.5, duration: .seconds(1))
        for activity in [awake, volume] {
            let content = ClosedContent(activity)
            let wings = metrics.closedWings(for: content)
            let size = metrics.closedSize(for: activity)
            let view = ClosedNotchView(content: content, metrics: metrics)
                .frame(width: size.width, height: size.height)
                .background(Color.black)
            let bitmap = try #require(Self.render(view, size: size, name: "closed-\(activity.title)"))
            let scale = CGFloat(bitmap.pixelsWide) / size.width
            // The columns anything light is drawn in, in points.
            let drawn = (0..<bitmap.pixelsWide).filter { x in
                (0..<bitmap.pixelsHigh).contains { y in
                    (bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.redComponent ?? 0) > 0.3
                }
            }.map { CGFloat($0) / scale }
            let camera = wings.leading...(wings.leading + metrics.housing.width)
            let inset = NotchMetrics.flare + NotchMetrics.closedPadding
            #expect(!drawn.isEmpty)
            #expect(!drawn.contains { camera.contains($0) }, "\(activity.title): nothing under the camera")
            #expect(drawn.min()! >= inset - 2, "\(activity.title): the leading piece starts at its inset")
            #expect(
                drawn.filter { $0 < camera.lowerBound }.max()! <= camera.lowerBound - NotchMetrics.closedPadding + 1,
                "\(activity.title): the label keeps its padding from the camera")
        }
    }

    private static func preferences() -> NotchPreferences {
        NotchPreferences(defaults: UserDefaults(suiteName: "Snapshots.\(UUID().uuidString)")!)
    }

    private func draw(
        _ name: String, metrics: NotchMetrics, events: [NotchEvent], preferences: NotchPreferences, badge: Int = 2
    ) throws {
        let engine = NotchEngine()
        engine.send(.setSpaces(preferences.spaceSet))
        events.forEach(engine.send)
        let content = NotchContent(
            feature: { feature in
                AnyView(Text("\(feature.title) content").frame(maxWidth: .infinity, maxHeight: .infinity))
            },
            now: { AnyView(Text("Now content").frame(maxWidth: .infinity, maxHeight: .infinity)) },
            badge: { $0 == .agents ? badge : 0 },
            actions: { space, _ in
                space == .shelf ? AnyView(DeckIconButton(.plus, label: "New") {}) : AnyView(EmptyView())
            },
            dropFiles: { _ in false },
            openSettings: {})
        let panel = metrics.panelFrame.size
        let view = NotchView(engine: engine, metrics: metrics, preferences: preferences, content: content)
            .frame(width: panel.width, height: panel.height)
            .background(Color(white: 0.82))  // stands in for the desktop behind the transparent panel
        let image = try #require(Self.render(view, size: panel, name: name))
        #expect(image.pixelsWide > 0 && image.pixelsHigh > 0)
    }

    /// Draws the view through the same AppKit hosting path the app uses (ImageRenderer can't draw
    /// AppKit-backed pieces such as the drop target and paints yellow placeholders over them). With
    /// SNAPSHOT_DIR set, also writes `<name>.png` there.
    /// `settle` lets what the view does on appearing happen before the picture is taken.
    static func render(_ view: some View, size: CGSize, name: String, settle: Bool = false) -> NSBitmapImageRep? {
        let host = NotchHostingView(rootView: view)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        if settle {
            RunLoop.main.run(until: .now + 0.6)
            host.layoutSubtreeIfNeeded()
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let png = bitmap.representation(using: .png, properties: [:])
            try? png?.write(to: URL(filePath: directory).appending(path: "\(name).png"))
        }
        return bitmap
    }
}
