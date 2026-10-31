// SPDX-License-Identifier: MIT
import AppKit
import CoreGraphics
import SwiftUI
import Testing
import TopdeckCore

@testable import TopdeckFeatures
@testable import TopdeckSurface

/// Shelf and Clipboard as the Shelf3 and Clipboard3 boards draw them. Always checks that each draws at the
/// open size; with SNAPSHOT_DIR set, every state at both sizes is drawn and written there as 2x PNGs
/// (`R3b-*`).
@MainActor
struct SpaceSnapshotTests {
    nonisolated static let pictures = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil
    nonisolated static let sizes = [("700x430", DeckScreen.normal), ("620x340", DeckScreen.smallest)]

    // MARK: Sample data

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "SpacesR3b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A picture with a blue to pink slope, as the board's screenshot has.
    private func picture(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors = [
            CGColor(red: 0.17, green: 0.3, blue: 0.49, alpha: 1), CGColor(red: 0.78, green: 0.42, blue: 0.48, alpha: 1),
        ]
        let gradient = try #require(CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1]))
        context.drawLinearGradient(
            gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.setFillColor(CGColor(gray: 1, alpha: 0.2))
        context.fill(CGRect(x: width / 12, y: height / 12, width: width * 10 / 12, height: height * 10 / 12))
        return try #require(context.makeImage())
    }

    private func data(_ image: CGImage, as type: NSBitmapImageRep.FileType) throws -> Data {
        try #require(NSBitmapImageRep(cgImage: image).representation(using: type, properties: [:]))
    }

    private func shelf(in folder: URL, filled: Bool) async throws -> ShelfFeature {
        let shelf = ShelfFeature(storeURL: folder.appending(path: "shelf.json"))
        if filled {
            let image = try picture(480, 320)
            let files: [(String, Data, Int)] = [
                ("Roof plan.pdf", pdf(), 2_400_000), ("Hero 2x.png", try data(image, as: .png), 812_000),
                ("Budget.xlsx", Data("xlsx".utf8), 96_000), ("Trip clip.mov", Data("mov".utf8), 48_000_000),
                ("Topdeck-0.8.dmg", Data("dmg".utf8), 21_000_000),
                ("Poster.jpg", try data(image, as: .jpeg), 1_200_000),
            ]
            let urls = try files.map { name, content, size -> URL in
                let url = folder.appending(path: name)
                try content.write(to: url)
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: UInt64(max(size, content.count)))  // sparse: the board's sizes
                try handle.close()
                return url
            }
            shelf.add(urls)
        }
        shelf.phase = .foreground
        if Self.pictures {  // the tiles' pictures arrive off the main thread: have them ready
            for url in shelf.locations.values {
                _ = await shelf.thumbnails.image(for: url, size: CGSize(width: 180, height: 120), scale: 2)
            }
        }
        return shelf
    }

    private func pdf() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let consumer = CGDataConsumer(data: data),
            let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return Data() }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: 30, y: 300, width: 160, height: 12))
        context.fill(CGRect(x: 30, y: 270, width: 220, height: 8))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func clipboard(in folder: URL, filled: Bool) throws -> ClipboardFeature {
        let now = Date.now
        let imagesURL = folder.appending(path: "Clipboard")
        var items: [ClipItem] = []
        if filled {
            try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
            func image(_ source: String, _ minutes: Double, _ size: (Int, Int)) throws -> ClipItem {
                let item = ClipItem(
                    kind: .image, text: "Image \(size.0) × \(size.1)", source: source,
                    copied: now.addingTimeInterval(-minutes * 60))
                try data(try picture(size.0, size.1), as: .png).write(
                    to: imagesURL.appending(path: "\(item.id.uuidString).png"))
                return item
            }
            let sheet = folder.appending(path: "Budget.xlsx")
            try Data("sheet".utf8).write(to: sheet)
            items = [
                try image("Preview", 2, (1440, 900)),
                ClipItem(
                    kind: .link, text: "https://github.com/fredcu/Topdeck", source: "Safari",
                    copied: now.addingTimeInterval(-8 * 60)),
                ClipItem(
                    kind: .text, text: "Meet at the north gate at six", source: "Messages",
                    copied: now.addingTimeInterval(-21 * 60)),
                try image("Photos", 60, (1200, 800)),
                ClipItem(kind: .files, text: sheet.path, source: "Finder", copied: now.addingTimeInterval(-2 * 3600)),
                ClipItem(
                    kind: .text, text: "make install DERIVED_DATA=…", source: "Terminal",
                    copied: now.addingTimeInterval(-3 * 3600)),
            ]
        }
        try JSONEncoder().encode(items).write(to: folder.appending(path: "clipboard.json"))
        let clipboard = ClipboardFeature(
            pasteboard: NSPasteboard(name: .init("SpacesR3b.\(UUID().uuidString)")),
            defaults: UserDefaults(suiteName: "SpacesR3b-\(UUID())")!,
            storeURL: folder.appending(path: "clipboard.json"),
            imagesURL: imagesURL, frontmostApp: { ("com.apple.Preview", "Preview") })
        clipboard.phase = .foreground
        clipboard.startRecording()
        return clipboard
    }

    private func draw(_ shelf: ShelfFeature, _ name: String, _ size: (String, CGSize)) throws {
        try DeckScreen.render(
            shelf.view, name: "R3b-\(name)-\(size.0)", size: size.1, space: .shelf, leading: shelf.headerLeading(),
            settle: Self.pictures ? 1.0 : 0, actions: shelf.headerActions)
    }

    private func draw(_ clipboard: ClipboardFeature, _ name: String, _ size: (String, CGSize)) throws {
        try DeckScreen.render(
            clipboard.view, name: "R3b-\(name)-\(size.0)", size: size.1, space: .clipboard,
            leading: clipboard.headerLeading(), actions: clipboard.headerActions)
    }

    // MARK: The open size, always

    @Test func shelfAndClipboardDrawAtTheOpenSize() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let shelf = try await shelf(in: folder, filled: true)
        try draw(shelf, "Shelf-full", Self.sizes[0])
        shelf.phase = .stopped
        let clipboard = try clipboard(in: folder, filled: true)
        try draw(clipboard, "Clipboard-All-image", Self.sizes[0])
        clipboard.phase = .stopped
    }

    // MARK: Every state at both sizes, when the pictures are wanted

    @Test(.enabled(if: SpaceSnapshotTests.pictures), arguments: SpaceSnapshotTests.sizes)
    func shelfStates(size: (String, CGSize)) async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let full = try await shelf(in: folder, filled: true)
        try draw(full, "Shelf-full", size)
        full.select(try #require(full.items.first))
        try draw(full, "Shelf-selected", size)
        full.phase = .stopped
        let empty = try await shelf(in: try self.folder(), filled: false)
        try draw(empty, "Shelf-empty", size)
    }

    @Test(.enabled(if: SpaceSnapshotTests.pictures), arguments: SpaceSnapshotTests.sizes)
    func clipboardStates(size: (String, CGSize)) throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clipboard = try clipboard(in: folder, filled: true)
        try draw(clipboard, "Clipboard-All-image", size)
        clipboard.chosen = clipboard.items[2].id
        clipboard.toggleFavorite(clipboard.items[2])
        try draw(clipboard, "Clipboard-Text", size)
        clipboard.chosen = clipboard.items[1].id
        try draw(clipboard, "Clipboard-Link", size)
        clipboard.chosen = clipboard.items[4].id
        try draw(clipboard, "Clipboard-Files", size)
        clipboard.chosen = nil
        clipboard.filter = .links
        clipboard.query = "zzz"
        try draw(clipboard, "Clipboard-NoMatch", size)
        clipboard.phase = .stopped
        let empty = try self.clipboard(in: try self.folder(), filled: false)
        try draw(empty, "Clipboard-empty", size)
    }
}
