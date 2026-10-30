// SPDX-License-Identifier: MIT
// The window list and its selection are adapted from OmniMac's WindowSwitcher
// (https://github.com/BySergiMM/OmniMac), Copyright (c) 2026 Sergi (BySergiMM), MIT License.
import CoreGraphics
import Foundation

/// One window in the switcher. `id` is its place in the enumeration, so it is unique even for windows
/// that have no CoreGraphics window number (minimized, or on another Space).
struct SwitcherEntry: Identifiable, Equatable {
    let id: Int
    let pid: pid_t
    let appName: String
    let title: String
    let isMinimized: Bool
    /// In Accessibility coordinates, which are the same as CoreGraphics' window list uses.
    let bounds: CGRect?
}

/// A window on screen, as CoreGraphics lists them front to back.
struct OnScreenWindow: Equatable {
    let windowID: CGWindowID
    let pid: pid_t
    let title: String
    let bounds: CGRect
}

enum SwitcherList {
    /// Which on-screen window each entry is, by app and frame, with the title breaking ties. Matching on
    /// the frame instead of asking the system for a window's number avoids a private call. Entries
    /// that match nothing (minimized, other Spaces) are left out.
    static func windowIDs(for entries: [SwitcherEntry], onScreen: [OnScreenWindow]) -> [Int: CGWindowID] {
        var used = Set<CGWindowID>()
        var result: [Int: CGWindowID] = [:]
        for entry in entries {
            guard let bounds = entry.bounds else { continue }
            let candidates = onScreen.filter {
                $0.pid == entry.pid && !used.contains($0.windowID) && close($0.bounds, bounds)
            }
            guard let match = candidates.first(where: { $0.title == entry.title }) ?? candidates.first else {
                continue
            }
            used.insert(match.windowID)
            result[entry.id] = match.windowID
        }
        return result
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2
            && abs(a.height - b.height) <= 2
    }

    /// Windows on screen first, front to back; then the others, open before minimized, by app name,
    /// and in the order they came in.
    static func ordered(
        _ entries: [SwitcherEntry], windowIDs: [Int: CGWindowID], onScreen: [OnScreenWindow]
    ) -> [SwitcherEntry] {
        let depth = Dictionary(
            onScreen.enumerated().map { ($1.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        func rank(_ entry: SwitcherEntry) -> Int? { windowIDs[entry.id].flatMap { depth[$0] } }
        return entries.sorted { a, b in
            switch (rank(a), rank(b)) {
            case (let x?, let y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                if a.isMinimized != b.isMinimized { return !a.isMinimized }
                let names = a.appName.localizedCaseInsensitiveCompare(b.appName)
                return names == .orderedSame ? a.id < b.id : names == .orderedAscending
            }
        }
    }

    /// The entries whose title or app name contain every word of `query`, ignoring case and accents.
    static func filter(_ entries: [SwitcherEntry], query: String) -> [SwitcherEntry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return entries }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return entries.filter { entry in
            words.allSatisfy {
                entry.title.range(of: $0, options: options) != nil
                    || entry.appName.range(of: $0, options: options) != nil
            }
        }
    }
}

/// Where the highlight is, and how keys move it.
enum SwitcherSelection {
    /// The second window, since the first is the one in front; the last when going backward. When the
    /// window in front is one the switcher doesn't list (Topdeck's own), the first is the one to go
    /// back to.
    static func initial(count: Int, backward: Bool, frontIsHidden: Bool = false) -> Int {
        guard count > 1 else { return 0 }
        if backward { return count - 1 }
        return frontIsHidden ? 0 : 1
    }

    /// One step along the list, wrapping at either end.
    static func step(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }

    /// A row up or down in a grid `columns` wide; stays put at the top and bottom.
    static func row(_ index: Int, by rows: Int, columns: Int, count: Int) -> Int {
        let target = index + rows * columns
        return (0..<count).contains(target) ? target : index
    }
}
