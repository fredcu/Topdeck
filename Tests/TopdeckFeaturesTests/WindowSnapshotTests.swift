// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import Testing

@testable import TopdeckFeatures

/// Renders the floating windows over a stand-in desktop, 1080 by 680 as on the boards. Always checks
/// that each draws; with SNAPSHOT_DIR set, also writes 2x PNGs there:
///
///     SNAPSHOT_DIR=/tmp/shots swift test --filter WindowSnapshot
@MainActor
struct WindowSnapshotTests {
    private let desktop = CGSize(width: 1080, height: 680)
    private let wall = Color(red: 0.22, green: 0.26, blue: 0.31)

    @Test func pinnedNotes() throws {
        func note(_ text: String, _ color: NoteColor, _ size: CGSize, hovering: Bool = false) -> some View {
            PinnedNoteSurface(
                text: .constant(text), color: color, mode: .top, hovering: hovering, setMode: { _ in }
            )
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
        }
        let scene = ZStack(alignment: .topLeading) {
            wall
            note(
                "Topdeck launch\nShip the new notch design first.\nThen record the demo.\n下周二前完成图标。", .yellow,
                CGSize(width: 240, height: 190)
            ).offset(x: 60, y: 80)
            note("Groceries\nMilk\nEggs\n牛油果", .blue, CGSize(width: 240, height: 150)).offset(x: 60, y: 292)
            note(
                "周末计划\n周六 游泳课 9:30\n周日 去 Bondi\nFinish the review", .green, CGSize(width: 270, height: 210),
                hovering: true
            ).offset(x: 760, y: 190)
        }
        try render(scene, size: desktop, name: "PinnedNotes")
    }

    @Test func commandBar() throws {
        let model = CommandBarModel()
        let keywords = "left half"
        model.search.setItems([
            CommandAction(
                id: "w1", title: "Left Half", area: "Window", symbol: "rectangle.split.2x1", keywords: keywords,
                shortcut: "⌃⌥←", run: {}),
            CommandAction(
                id: "w2", title: "Left Two Thirds", area: "Window", symbol: "rectangle.split.2x1", keywords: keywords,
                run: {}),
            CommandAction(
                id: CommandAction.appPrefix + "/Applications/Xcode.app", title: "Xcode", area: "App", symbol: "",
                keywords: keywords, run: {}),
            CommandAction(
                id: "n", title: "Open Notes", area: "Stash", symbol: "note.text", keywords: keywords, run: {}),
            CommandAction(
                id: "s", title: "Windows Settings", area: "Settings", symbol: "gearshape", keywords: keywords, run: {}),
        ])
        model.search.setQuery("left half")
        let rows = model.search.results.count
        let height = CommandBarView.height(rows: rows, hasQuery: true)
        let scene = ZStack(alignment: .topLeading) {
            wall
            CommandBarView(model: model).frame(width: CommandBarView.width, height: height)
                .shadow(color: .black.opacity(0.6), radius: 40, y: 20).offset(x: 220, y: 120)
        }
        try render(scene, size: desktop, name: "CommandBar")
    }

    @Test func switcher() throws {
        let apps: [(String, String, String, Color)] = [
            ("Xcode", "AppDelegate.swift", "/Applications/Xcode.app", Color(white: 0.14)),
            ("Safari", "GitHub", "/Applications/Safari.app", Color(white: 0.91)),
            ("Terminal", "zsh", "/System/Applications/Utilities/Terminal.app", Color(white: 0.06)),
            ("Pages", "Plan.pages", "/Applications/Pages.app", Color(white: 0.98)),
            ("Music", "Music", "/System/Applications/Music.app", Color(red: 0.16, green: 0.11, blue: 0.14)),
            ("Messages", "Messages", "/System/Applications/Messages.app", Color(white: 0.14)),
            ("Notes", "Notes", "/System/Applications/Notes.app", Color(white: 0.14)),
            ("Preview", "Preview", "/System/Applications/Preview.app", Color(white: 0.14)),
        ]
        let model = SwitcherModel()
        model.showsThumbnails = true
        for (index, app) in apps.enumerated() {
            let entry = SwitcherEntry(
                id: index, pid: pid_t(index), appName: app.0, title: app.1, isMinimized: app.0 == "Preview", bounds: nil
            )
            model.all.append(entry)
            model.icons[entry.pid] = NSWorkspace.shared.icon(forFile: app.2)
            if index < 4 {
                model.windowIDs[index] = CGWindowID(index)
                model.thumbnails[CGWindowID(index)] = thumbnail(app.3)
            }
        }
        model.columns = 4
        model.selection = 0
        let size = CGSize(width: 902, height: 2 * 166 + 10 + 32)
        let scene = ZStack(alignment: .topLeading) {
            wall
            SwitcherView(model: model) { _ in }.frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(0.6), radius: 40, y: 20).offset(x: 89, y: 190)
        }
        try render(scene, size: desktop, name: "Switcher")
    }

    @Test func markup() throws {
        let image = try #require(shot())
        let editor = MarkupWindow(capture: CaptureImage(image: image, scale: 2)) { _, _ in }
        editor.window.setContentSize(CGSize(width: 960, height: 600))
        let model = editor.model
        model.tool = .rectangle
        model.press(at: CGPoint(x: 24, y: 192))
        model.release(at: CGPoint(x: 400, y: 428))
        model.tool = .arrow
        model.press(at: CGPoint(x: 560, y: 400))
        model.release(at: CGPoint(x: 420, y: 330))
        model.tool = .counter
        model.press(at: CGPoint(x: 25, y: 193))
        model.release(at: CGPoint(x: 25, y: 193))
        model.tool = .arrow
        try render(editor.window.contentView!, size: CGSize(width: 960, height: 600), name: "Markup")
    }

    @Test func scrollingStatus() throws {
        let status = ScrollingStatus()
        status.pixels = 1840
        let steady = ScrollingHUD(status: status, done: {}, cancel: {})
        let behind = ScrollingStatus()
        behind.pixels = 1840
        behind.lost = true
        let lost = ScrollingHUD(status: behind, done: {}, cancel: {})
        let scene = VStack(spacing: 16) {
            steady
            lost
        }.padding(24).background(wall)
        try render(scene, size: CGSize(width: 440, height: 160), name: "ScrollingStatus")
    }

    /// A light page, like the board's capture.
    private func shot() -> CGImage? {
        let size = CGSize(width: 840, height: 510)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor(white: 0.96, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.9, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 840, height: 40).fill()
            NSColor(white: 0.85, alpha: 1).setFill()
            for (y, w) in [(112, 620), (136, 560), (160, 600)] {
                NSBezierPath(roundedRect: NSRect(x: 32, y: y, width: w, height: 10), xRadius: 5, yRadius: 5).fill()
            }
            NSColor(red: 0.81, green: 0.89, blue: 0.98, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 32, y: 200, width: 360, height: 220), xRadius: 12, yRadius: 12).fill()
            NSColor(white: 0.9, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 420, y: 200, width: 380, height: 100), xRadius: 12, yRadius: 12).fill()
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: AffineTransform(scale: 2)])
    }

    private func thumbnail(_ color: Color) -> NSImage {
        NSImage(size: CGSize(width: 400, height: 250), flipped: true) { rect in
            NSColor(color).setFill()
            rect.fill()
            NSColor.gray.withAlphaComponent(0.5).setFill()
            for y in [30, 62, 94] {
                NSBezierPath(roundedRect: NSRect(x: 24, y: y, width: 300, height: 12), xRadius: 6, yRadius: 6).fill()
            }
            return true
        }
    }

    private func render(_ view: some View, size: CGSize, name: String) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        try render(host, size: size, name: name)
    }

    private func render(_ host: NSView, size: CGSize, name: String) throws {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        if host.window == nil { window.contentView = host }
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now + 0.15)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide == Int(size.width * 2))
        if let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(filePath: directory).appending(path: "\(name).png"))
        }
    }
}
