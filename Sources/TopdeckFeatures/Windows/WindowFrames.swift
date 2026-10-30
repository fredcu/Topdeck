// SPDX-License-Identifier: MIT
// Adapted from Rectangle (https://github.com/rxhanson/Rectangle), Copyright (c) 2019-2026 Ryan Hanson,
// MIT License: its halves, thirds, corners, almost maximize, next display and gap calculations.
import CoreGraphics
import Foundation

/// Somewhere a window can go.
public enum WindowAction: String, CaseIterable, Codable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case maximize, almostMaximize
    case nextDisplay

    public var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .firstThird: "First Third"
        case .centerThird: "Center Third"
        case .lastThird: "Last Third"
        case .firstTwoThirds: "First Two Thirds"
        case .lastTwoThirds: "Last Two Thirds"
        case .maximize: "Maximize"
        case .almostMaximize: "Almost Maximize"
        case .nextDisplay: "Next Display"
        }
    }
}

/// Window frames for each action. Everything is in AppKit's screen coordinates: the origin at the
/// bottom left of the primary display, y going up. `visible` is a screen's frame without the menu
/// bar and the Dock.
public enum WindowFrames {
    /// The widths a half or a corner steps through when its action is repeated.
    static let cycle: [CGFloat] = [1 / 2, 2 / 3, 1 / 3]
    static let almostMaximizeScale: CGFloat = 0.9
    /// How far a window may sit from a frame and still count as there: some apps round their size.
    static let tolerance: CGFloat = 2

    /// Where `action` puts a window that's now at `window`, with `gap` points around and between
    /// windows. Repeating an action on a window already in place takes the next size or place: a half
    /// goes to two thirds, then one third. Nil for Next Display, which needs the other screens: see
    /// `moved(_:from:to:gap:)`. Without a window, the first frame.
    public static func frame(for action: WindowAction, window: CGRect?, in visible: CGRect, gap: CGFloat = 0)
        -> CGRect?
    {
        let gap = action == .almostMaximize ? 0 : gap
        let frames = steps(for: action, in: visible).map { gapped($0, in: visible, gap) }
        guard let first = frames.first else { return nil }
        guard let window, let current = frames.firstIndex(where: { matches(window, $0) }) else { return first }
        return frames[(current + 1) % frames.count]
    }

    /// The frames an action steps through, first press first.
    static func steps(for action: WindowAction, in visible: CGRect) -> [CGRect] {
        switch action {
        case .leftHalf: cycle.map { column(visible, $0, leading: true) }
        case .rightHalf: cycle.map { column(visible, $0, leading: false) }
        case .topHalf: [row(visible, 1 / 2, top: true)]
        case .bottomHalf: [row(visible, 1 / 2, top: false)]
        case .topLeft: cycle.map { corner(visible, $0, leading: true, top: true) }
        case .topRight: cycle.map { corner(visible, $0, leading: false, top: true) }
        case .bottomLeft: cycle.map { corner(visible, $0, leading: true, top: false) }
        case .bottomRight: cycle.map { corner(visible, $0, leading: false, top: false) }
        case .firstThird: [0, 1, 2].map { third(visible, $0) }
        case .centerThird: [third(visible, 1)]
        case .lastThird: [2, 1, 0].map { third(visible, $0) }
        case .firstTwoThirds: [twoThirds(visible, first: true), twoThirds(visible, first: false)]
        case .lastTwoThirds: [twoThirds(visible, first: false), twoThirds(visible, first: true)]
        case .maximize: [visible]
        case .almostMaximize: [almostMaximized(visible)]
        case .nextDisplay: []
        }
    }

    // MARK: Pieces of a screen

    /// A full-height column `fraction` of the width, on the left or the right.
    static func column(_ visible: CGRect, _ fraction: CGFloat, leading: Bool) -> CGRect {
        var rect = visible
        rect.size.width = floored(visible.width * fraction)
        if !leading { rect.origin.x = visible.maxX - rect.width }
        return rect
    }

    /// A full-width row `fraction` of the height, at the top or the bottom.
    static func row(_ visible: CGRect, _ fraction: CGFloat, top: Bool) -> CGRect {
        var rect = visible
        rect.size.height = floored(visible.height * fraction)
        if top { rect.origin.y = visible.maxY - rect.height }
        return rect
    }

    /// Half the height, and `fraction` of the width.
    static func corner(_ visible: CGRect, _ fraction: CGFloat, leading: Bool, top: Bool) -> CGRect {
        let column = column(visible, fraction, leading: leading)
        let row = row(visible, 1 / 2, top: top)
        return CGRect(x: column.minX, y: row.minY, width: column.width, height: row.height)
    }

    /// Third `index` (0 to 2): columns from the left on a landscape screen, rows from the top on a
    /// portrait one.
    static func third(_ visible: CGRect, _ index: Int) -> CGRect {
        var rect = visible
        if visible.width > visible.height {
            rect.size.width = floored(visible.width / 3)
            rect.origin.x = index == 2 ? visible.maxX - rect.width : visible.minX + CGFloat(index) * rect.width
        } else {
            rect.size.height = floored(visible.height / 3)
            rect.origin.y = index == 2 ? visible.minY : visible.maxY - CGFloat(index + 1) * rect.height
        }
        return rect
    }

    /// The first or last two thirds, across a landscape screen or down a portrait one.
    static func twoThirds(_ visible: CGRect, first: Bool) -> CGRect {
        var rect = visible
        if visible.width > visible.height {
            rect.size.width = floored(visible.width * 2 / 3)
            if !first { rect.origin.x = visible.maxX - rect.width }
        } else {
            rect.size.height = floored(visible.height * 2 / 3)
            if first { rect.origin.y = visible.maxY - rect.height }
        }
        return rect
    }

    /// Nine tenths of the width and height, centered.
    static func almostMaximized(_ visible: CGRect) -> CGRect {
        let width = (visible.width * almostMaximizeScale).rounded()
        let height = (visible.height * almostMaximizeScale).rounded()
        return CGRect(
            x: visible.minX + ((visible.width - width) / 2).rounded(),
            y: visible.minY + ((visible.height - height) / 2).rounded(), width: width, height: height)
    }

    /// `gap` points inside the screen's edges, and half of it on edges shared with another window,
    /// so two windows side by side have one gap between them.
    static func gapped(_ rect: CGRect, in visible: CGRect, _ gap: CGFloat) -> CGRect {
        guard gap > 0 else { return rect }
        func inset(_ edge: CGFloat, _ screenEdge: CGFloat) -> CGFloat {
            abs(edge - screenEdge) < 1 ? gap : gap / 2
        }
        let left = inset(rect.minX, visible.minX)
        let right = inset(rect.maxX, visible.maxX)
        let bottom = inset(rect.minY, visible.minY)
        let top = inset(rect.maxY, visible.maxY)
        return CGRect(
            x: rect.minX + left, y: rect.minY + bottom, width: rect.width - left - right,
            height: rect.height - bottom - top)
    }

    private static func floored(_ value: CGFloat) -> CGFloat { (value + 0.0001).rounded(.down) }

    static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    // MARK: Displays

    /// The screen showing most of `window`, as an index into `screens` (their whole frames), or the
    /// nearest one when it's on none of them. Nil without screens.
    public static func screen(for window: CGRect, in screens: [CGRect]) -> Int? {
        func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
        func distance(_ screen: CGRect) -> CGFloat {
            let (x, y) = (screen.midX - window.midX, screen.midY - window.midY)
            return x * x + y * y
        }
        let overlaps = screens.map { area($0.intersection(window)) }
        if let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 { return best }
        return screens.indices.min { distance(screens[$0]) < distance(screens[$1]) }
    }

    /// The screen after `current` for Next Display: left to right, then top to bottom, round to
    /// the first. Nil with one screen.
    public static func nextScreen(after current: Int, in screens: [CGRect]) -> Int? {
        guard screens.count > 1, screens.indices.contains(current) else { return nil }
        let order = screens.indices.sorted {
            let (a, b) = (screens[$0], screens[$1])
            return a.minX != b.minX ? a.minX < b.minX : a.maxY > b.maxY
        }
        guard let position = order.firstIndex(of: current) else { return nil }
        return order[(position + 1) % order.count]
    }

    /// `window` moved from one screen's visible frame to another's. A maximized window stays
    /// maximized; any other keeps its place and size as parts of the screen, and stays inside it.
    public static func moved(_ window: CGRect, from source: CGRect, to destination: CGRect, gap: CGFloat = 0)
        -> CGRect
    {
        if matches(window, gapped(source, in: source, gap)) || matches(window, source) {
            return gapped(destination, in: destination, gap)
        }
        guard source.width > 0, source.height > 0 else { return window }
        let width = min((window.width / source.width * destination.width).rounded(), destination.width)
        let height = min((window.height / source.height * destination.height).rounded(), destination.height)
        var x = destination.minX + ((window.minX - source.minX) / source.width * destination.width).rounded()
        var y = destination.minY + ((window.minY - source.minY) / source.height * destination.height).rounded()
        x = min(max(x, destination.minX), destination.maxX - width)
        y = min(max(y, destination.minY), destination.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Between AppKit's coordinates and the Accessibility API's, which put the origin at the top
    /// left of the primary display with y going down. The same flip goes both ways.
    public static func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
