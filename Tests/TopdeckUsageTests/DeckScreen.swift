// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import Testing
import TopdeckSurface

/// A screen drawn the way the deck draws it: a black panel with the second row (its sub-tabs and
/// actions) over the body. Always checks that it draws; with SNAPSHOT_DIR set, also writes a 2x PNG there.
@MainActor
enum DeckScreen {
    /// The open deck's default size and its smallest.
    static let normal = CGSize(width: 700, height: 430)
    static let smallest = CGSize(width: 620, height: 340)

    static func render(
        _ body: some View, name: String, size: CGSize = normal, tabs: [String], selected: String,
        actions: some View = EmptyView()
    ) throws {
        let deck = VStack(spacing: 0) {
            Color.clear.frame(height: 37)  // the row beside the camera
            HStack(spacing: 0) {
                DeckSubTabs(tabs, selection: selected, title: { $0 }, select: { _ in })
                Spacer(minLength: Deck.Metric.gap)
                HStack(spacing: 2) {
                    actions
                    DeckIconButton(.pin, label: "Keep open") {}
                    DeckIconButton(.gear, label: "Settings") {}
                }
            }
            .padding(.horizontal, 18)
            .frame(height: Deck.Metric.subRow)
            body
                .padding(.horizontal, Deck.Metric.side)
                .padding(.bottom, Deck.Metric.side)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: size.width, height: size.height)
        .background(Deck.deck, in: UnevenRoundedRectangle(bottomLeadingRadius: 30, bottomTrailingRadius: 30))
        .padding(16)
        .background(Color(red: 0.22, green: 0.26, blue: 0.31))
        .foregroundStyle(Deck.text)
        .environment(\.colorScheme, .dark)
        // A hosting view, not ImageRenderer, which leaves scroll views blank. Drawn into a bitmap of
        // twice the pixels, as on a Retina display.
        let host = NSHostingView(rootView: deck)
        let area = CGSize(width: size.width + 32, height: size.height + 32)
        host.frame = CGRect(origin: .zero, size: area)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(area.width) * 2, pixelsHigh: Int(area.height) * 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = area
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        if let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(filePath: directory).appending(path: "\(name).png"))
        }
    }
}
