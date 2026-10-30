// SPDX-License-Identifier: MIT
// Adapted from Rectangle (https://github.com/rxhanson/Rectangle), Copyright (c) 2019-2026 Ryan Hanson,
// MIT License: its snap edge detection and default snap areas.
import CoreGraphics
import Foundation

/// Where dragging a window to the edge of a screen puts it: corners to quarters, the top to maximize,
/// the sides to halves, and the bottom to thirds. A portrait screen swaps the last two.
public enum SnapAreas {
    /// How close to an edge the pointer has to be.
    static let margin: CGFloat = 5
    /// How far along an edge from a corner the corner reaches.
    static let corner: CGFloat = 20
    /// How far from the top and bottom of a side edge goes to a top or bottom half instead.
    static let shortEdge: CGFloat = 145

    /// The action for a drag at `point` on the screen whose whole frame is `frame`, or nil away from
    /// its edges. `prior` is the action the drag offered before, so sliding along the bottom from a
    /// third to the middle widens it to two thirds.
    public static func action(at point: CGPoint, in frame: CGRect, prior: WindowAction? = nil) -> WindowAction? {
        guard let edge = edge(at: point, in: frame) else { return nil }
        let landscape = frame.width > frame.height
        switch edge {
        case .topLeft: return .topLeft
        case .topRight: return .topRight
        case .bottomLeft: return .bottomLeft
        case .bottomRight: return .bottomRight
        case .top: return .maximize
        case .left, .right:
            if point.y <= frame.minY + margin + shortEdge { return .bottomHalf }
            if point.y >= frame.maxY - margin - shortEdge { return .topHalf }
            guard landscape else { return thirds(along: frame.maxY - point.y, of: frame.height, prior: prior) }
            return edge == .left ? .leftHalf : .rightHalf
        case .bottom:
            guard landscape else { return point.x < frame.midX ? .leftHalf : .rightHalf }
            return thirds(along: point.x - frame.minX, of: frame.width, prior: prior)
        }
    }

    /// A third by where the pointer is along an edge, from the left or the top; the middle widens to
    /// two thirds toward the side the drag came from.
    private static func thirds(along offset: CGFloat, of length: CGFloat, prior: WindowAction?) -> WindowAction {
        let third = (length / 3).rounded(.down)
        if offset <= third { return .firstThird }
        if offset >= length - third { return .lastThird }
        switch prior {
        case .firstThird, .firstTwoThirds: return .firstTwoThirds
        case .lastThird, .lastTwoThirds: return .lastTwoThirds
        default: return .centerThird
        }
    }

    enum Edge {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
    }

    /// Which edge or corner of `frame` the pointer is at, counting the far edges as inside.
    static func edge(at point: CGPoint, in frame: CGRect) -> Edge? {
        guard point.x >= frame.minX, point.x <= frame.maxX, point.y >= frame.minY, point.y <= frame.maxY else {
            return nil
        }
        let nearTop = point.y >= frame.maxY - margin - corner
        let nearBottom = point.y <= frame.minY + margin + corner
        if point.x < frame.minX + margin + corner {
            if nearTop { return .topLeft }
            if nearBottom { return .bottomLeft }
        }
        if point.x > frame.maxX - margin - corner {
            if nearTop { return .topRight }
            if nearBottom { return .bottomRight }
        }
        if point.x < frame.minX + margin { return .left }
        if point.x > frame.maxX - margin { return .right }
        if point.y > frame.maxY - margin { return .top }
        if point.y < frame.minY + margin { return .bottom }
        return nil
    }
}
