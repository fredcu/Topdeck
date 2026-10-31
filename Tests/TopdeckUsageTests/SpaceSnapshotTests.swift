// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import Testing
import TopdeckCore

@testable import TopdeckFeatures
@testable import TopdeckSurface

/// Shelf and Clipboard in the deck's new colours, at both sizes. Always checks that each draws; with
/// SNAPSHOT_DIR set, also writes 2x PNGs there.
@MainActor
struct SpaceSnapshotTests {
    @Test func shelfWithFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ShelfR3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try ["Roof plan.pdf", "Hero 2x.png", "Budget.xlsx", "Notes.txt", "Archive.zip"].map { name in
            let url = folder.appending(path: name)
            try Data(name.utf8).write(to: url)
            return url
        }
        let shelf = ShelfFeature(storeURL: folder.appending(path: "shelf.json"))
        shelf.add(files)
        shelf.phase = .foreground
        try DeckScreen.render(shelf.view, name: "Shelf", space: .shelf, actions: shelf.headerActions)
        try DeckScreen.render(
            shelf.view, name: "Shelf-min", size: DeckScreen.smallest, space: .shelf, actions: shelf.headerActions)
        shelf.phase = .stopped
    }

    @Test func clipboardWithAHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClipboardR3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pasteboard = NSPasteboard(name: .init("ClipboardR3.\(UUID().uuidString)"))
        let clipboard = ClipboardFeature(
            pasteboard: pasteboard, defaults: UserDefaults(suiteName: "CR3-\(UUID())")!,
            storeURL: folder.appending(path: "clipboard.json"), imagesURL: folder.appending(path: "Clipboard"),
            frontmostApp: { ("com.apple.Safari", "Safari") })
        clipboard.phase = .foreground
        clipboard.startRecording()
        for text in ["Meeting at 4 in the big room", "https://github.com/fredcu/Topdeck", "make install"] {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            clipboard.check()
        }
        clipboard.toggleFavorite(try #require(clipboard.items.last))
        try DeckScreen.render(clipboard.view, name: "Clipboard", space: .clipboard, actions: clipboard.headerActions)
        try DeckScreen.render(
            clipboard.view, name: "Clipboard-min", size: DeckScreen.smallest, space: .clipboard,
            actions: clipboard.headerActions)
        clipboard.phase = .stopped
    }
}
