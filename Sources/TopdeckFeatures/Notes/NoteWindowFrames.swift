// SPDX-License-Identifier: MIT
import CoreGraphics
import Foundation

/// A display a note window can go on: its UUID, which stays the same across reconnects, and the part
/// of it outside the menu bar and Dock, in screen coordinates.
struct NoteScreen: Equatable, Sendable {
    let id: String
    let visibleFrame: CGRect
}

/// Where each note's window was put, per display, kept in UserDefaults so dragging a window doesn't
/// rewrite its file. `home` is the display the user last placed it on while that display was there:
/// a window moved off an unplugged display, and dragged about meanwhile, still goes back on its return.
@MainActor
struct NoteFrameStore {
    struct Entry: Codable, Equatable {
        var home: String
        var frames: [String: CGRect]
    }

    private static let key = "notes.windowFrames"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func entry(for id: Note.ID) -> Entry? { all[id.uuidString] }

    /// Keeps a frame the user gave a window on `display`. `connected` are the displays there now.
    func record(_ frame: CGRect, on display: String, for id: Note.ID, connected: Set<String>) {
        var entries = all
        var entry = entries[id.uuidString] ?? Entry(home: display, frames: [:])
        entry.frames[display] = frame
        if connected.contains(entry.home) { entry.home = display }
        entries[id.uuidString] = entry
        all = entries
    }

    /// Forgets a deleted note's frames.
    func remove(_ id: Note.ID) {
        var entries = all
        guard entries.removeValue(forKey: id.uuidString) != nil else { return }
        all = entries
    }

    private var all: [String: Entry] {
        get {
            guard let data = defaults.data(forKey: Self.key) else { return [:] }
            return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// Where a note's window goes on the displays there now. Coordinates are AppKit's: y grows upwards.
enum NoteWindowPlacement {
    struct Placement: Equatable {
        let frame: CGRect
        let display: String
    }

    static let defaultSize = CGSize(width: 240, height: 200)
    /// From the top right corner of the screen, and between new windows.
    static let margin: CGFloat = 24

    /// The frame and display for a window with `entry` saved. Its home display wins; when that one is
    /// gone, a display the window was also placed on; otherwise the first screen, at the same size.
    /// The saved entry is left as it was, so the window goes home when its display returns. `index`
    /// staggers windows that have nowhere saved. Nil when there are no screens at all.
    static func place(_ entry: NoteFrameStore.Entry?, on screens: [NoteScreen], index: Int = 0) -> Placement? {
        if let entry {
            let saved = screens.first { $0.id == entry.home } ?? screens.first { entry.frames[$0.id] != nil }
            if let screen = saved, let frame = entry.frames[screen.id] {
                return Placement(frame: fit(frame, in: screen.visibleFrame), display: screen.id)
            }
        }
        guard let screen = screens.first else { return nil }
        let size = entry.flatMap { $0.frames[$0.home]?.size } ?? defaultSize
        let visible = screen.visibleFrame
        let inset = margin * CGFloat(index + 1)
        let origin = CGPoint(x: visible.maxX - inset - size.width, y: visible.maxY - inset - size.height)
        return Placement(frame: fit(CGRect(origin: origin, size: size), in: visible), display: screen.id)
    }

    /// `frame` moved, and shrunk if need be, to lie wholly inside `visible`.
    static func fit(_ frame: CGRect, in visible: CGRect) -> CGRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
