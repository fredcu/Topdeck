// SPDX-License-Identifier: MIT
import CoreGraphics
import Foundation

/// A saved arrangement of windows: where each app's windows were, as parts of their display, so it
/// comes back the same on a display of another size.
public struct WindowLayout: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var placements: [Placement]

    public init(id: UUID = UUID(), name: String, placements: [Placement]) {
        self.id = id
        self.name = name
        self.placements = placements
    }

    public struct Placement: Codable, Hashable, Sendable {
        /// The app's bundle ID.
        public var app: String
        /// The window's title when it was saved, to tell an app's windows apart.
        public var title: String
        /// The display's UUID.
        public var display: String
        /// The window's frame as fractions of the display's visible frame, from its bottom left.
        public var frame: CGRect

        public init(app: String, title: String, display: String, frame: CGRect) {
            self.app = app
            self.title = title
            self.display = display
            self.frame = frame
        }
    }

    /// An open window a layout can place.
    public struct Window: Hashable, Sendable {
        public var app: String
        public var title: String

        public init(app: String, title: String) {
            self.app = app
            self.title = title
        }
    }

    /// Which placement each open window takes, by its index in `windows`. Within an app, a window
    /// takes the placement saved under its title first; the rest pair up in order. Windows left over
    /// stay where they are.
    public func assignments(for windows: [Window]) -> [Int: Placement] {
        var unused = Array(placements.indices)
        var result: [Int: Placement] = [:]
        for (index, window) in windows.enumerated() {
            let saved = unused.firstIndex { placements[$0].app == window.app && placements[$0].title == window.title }
            guard let saved else { continue }
            result[index] = placements[unused.remove(at: saved)]
        }
        for (index, window) in windows.enumerated() where result[index] == nil {
            guard let saved = unused.firstIndex(where: { placements[$0].app == window.app }) else { continue }
            result[index] = placements[unused.remove(at: saved)]
        }
        return result
    }

    /// `frame` as fractions of `visible`.
    public static func unit(_ frame: CGRect, in visible: CGRect) -> CGRect {
        guard visible.width > 0, visible.height > 0 else { return .zero }
        return CGRect(
            x: (frame.minX - visible.minX) / visible.width, y: (frame.minY - visible.minY) / visible.height,
            width: frame.width / visible.width, height: frame.height / visible.height)
    }

    /// Fractions of `visible` back to a frame in whole points.
    public static func frame(_ unit: CGRect, in visible: CGRect) -> CGRect {
        CGRect(
            x: (visible.minX + unit.minX * visible.width).rounded(),
            y: (visible.minY + unit.minY * visible.height).rounded(),
            width: (unit.width * visible.width).rounded(), height: (unit.height * visible.height).rounded())
    }

    /// Layouts as UserDefaults keeps them; nothing stored, or something unreadable, is no layouts.
    public static func decode(_ data: Data?) -> [WindowLayout] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([WindowLayout].self, from: data)) ?? []
    }

    public static func encode(_ layouts: [WindowLayout]) -> Data {
        (try? JSONEncoder().encode(layouts)) ?? Data()
    }
}
