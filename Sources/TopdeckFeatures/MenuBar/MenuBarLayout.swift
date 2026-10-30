// SPDX-License-Identifier: MIT
// Adapted from OmniMac (https://github.com/BySergiMM/OmniMac) at 6a56641: Features/MenuBar/MenuBarFeature.swift.
// Copyright (c) 2026 Sergi (BySergiMM). MIT License; changed for Topdeck: the position and width rules only,
// with comments translated from Spanish. See THIRD_PARTY_NOTICES.md.
import Foundation

/// Where the hider's status items sit in the menu bar, and how wide the expander grows. macOS keeps
/// each named item's place in the defaults as "distance from the right edge": a larger number is
/// further left.
enum MenuBarLayout {
    /// The invisible-when-collapsed item that grows to push everything on its left out of view.
    static let expanderName = "net.icuai.topdeck.menubar.expander"
    /// The arrow the user clicks.
    static let separatorName = "net.icuai.topdeck.menubar.separator"
    /// Topdeck's own menu bar item, which must never end up behind the expander.
    static let ownName = "net.icuai.topdeck.status"

    /// Factory positions, left to right. The expander is the user's boundary once they've moved it.
    static let defaults: [(name: String, position: Double)] = [
        (expanderName, 380), (separatorName, 362), (ownName, 344),
    ]
    static let spacing = 18.0

    /// How long an opened bar stays open, in seconds, and the choices Settings offers.
    static let defaultDelay = 10.0
    static let delays: [Double] = [3, 5, 10, 30, 60]

    static func key(_ name: String) -> String { "NSStatusItem Preferred Position \(name)" }

    /// The stored position. macOS writes it as a decimal, so it reads as one.
    static func position(_ name: String, in defaults: UserDefaults) -> Double? {
        (defaults.object(forKey: key(name)) as? NSNumber)?.doubleValue
    }

    /// Our items, in order, as `defaults` lists them without the expander.
    static var ownNames: [String] { defaults.dropFirst().map(\.name) }

    /// True when an item of ours sits at or left of the expander, where it would be hidden with the rest.
    static func isSwallowed(in defaults: UserDefaults) -> Bool {
        guard let limit = position(expanderName, in: defaults) else { return true }
        return ownNames.contains { (position($0, in: defaults) ?? .infinity) >= limit }
    }

    /// Puts our items to the right of the expander, in order, and returns whether it moved any. The
    /// expander is never moved: it's the boundary the user set by dragging icons, and resetting it would
    /// uncover everything they hid. `force` replaces the positions of all of ours.
    ///
    /// Call it before creating the items: AppKit reads a position when the item is made.
    @discardableResult
    static func place(in defaults: UserDefaults, force: Bool = false) -> Bool {
        let limit = position(expanderName, in: defaults) ?? Self.defaults[0].position
        defaults.set(limit, forKey: key(expanderName))
        let current = ownNames.reduce(into: [String: Double]()) { $0[$1] = position($1, in: defaults) }
        let moves = placements(for: ownNames, current: current, limit: limit, force: force)
        for (name, value) in moves { defaults.set(value, forKey: key(name)) }
        return !moves.isEmpty
    }

    /// Which items to move and where, given where they are: only the ones that left their row.
    static func placements(
        for names: [String], current: [String: Double], limit: Double, force: Bool
    ) -> [String: Double] {
        var result: [String: Double] = [:]
        var next = limit - spacing
        for name in names {
            if !force, let position = current[name], position <= next {
                next = position - spacing
                continue
            }
            result[name] = next
            next -= spacing
        }
        return result
    }

    /// AppKit erases an item's stored position when the item is removed; these put them back.
    static func saved(_ names: [String], in defaults: UserDefaults) -> [String: Double] {
        names.reduce(into: [:]) { $0[$1] = position($1, in: defaults) }
    }

    static func restore(_ positions: [String: Double], in defaults: UserDefaults) {
        for (name, value) in positions { defaults.set(value, forKey: key(name)) }
    }

    /// The expander's width while collapsed. Up to macOS 26 anything wider than the screen worked.
    /// macOS 27 draws the bar as one window and silently drops an item wider than half a screen, so
    /// the cap is 45% of the narrowest screen. On a Mac with a notch that is still too wide: the
    /// expander would cross it and the hidden icons reappear beside the app's menus, so when the
    /// distance from the expander's right edge to the notch's right edge is known (`notchGap`), the
    /// width stops just past it and the icons tuck under the notch.
    static func pushWidth(screenWidths: [Double], macOS27: Bool, notchGap: Double? = nil) -> Double {
        guard macOS27 else { return 10_000 }
        let base = max(200, ((screenWidths.min() ?? 1440) * 0.45).rounded(.down))
        guard let notchGap, notchGap > 0 else { return base }
        return max(200, min(base, (notchGap + 12).rounded(.down)))
    }
}
