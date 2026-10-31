// SPDX-License-Identifier: MIT
// Adapted from Snapzy (https://github.com/duongductrong/Snapzy) at 77d3d3f: Features/VideoEditor/Services/VideoEditorZoomCalculator.swift.
// Copyright (c) 2026, Trong Duong Duc. BSD 3-Clause License; see THIRD_PARTY_NOTICES.md.
import CoreGraphics
import Foundation

/// Where the camera is at one moment: how far in, and on what, as fractions of the picture from its top left.
public struct ZoomCamera: Equatable, Sendable {
    public var scale: Double
    public var center: CGPoint

    public static let still = ZoomCamera(scale: 1, center: CGPoint(x: 0.5, y: 0.5))

    /// The part of the picture the camera sees, kept inside it.
    public var view: CGRect {
        guard scale > 1 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let side = 1 / scale
        return CGRect(
            x: min(max(center.x - side / 2, 0), 1 - side), y: min(max(center.y - side / 2, 0), 1 - side), width: side,
            height: side)
    }
}

/// The camera over time, from the zoom segments and the recorded pointer. It is a pure function of the source
/// time, so the preview, the export and a scrub all agree.
public struct ZoomPlan: Sendable {
    public let segments: [ZoomSegment]
    public let cursor: CursorTrack?

    /// How long the camera takes to go in, and to come out, at most.
    public static let transition: TimeInterval = 0.4

    public init(segments: [ZoomSegment], cursor: CursorTrack?) {
        self.segments = segments.sorted { $0.start < $1.start }
        self.cursor = cursor?.isUsable == true ? cursor : nil
    }

    public var isEmpty: Bool { segments.isEmpty }

    public func camera(at time: TimeInterval) -> ZoomCamera {
        guard let segment = segments.last(where: { time >= $0.start && time < $0.end }) else { return .still }
        let local = time - segment.start
        let edge = min(Self.transition, segment.duration * 0.45)
        let progress: Double
        if local < edge {
            progress = Self.ease(local / edge)
        } else if local > segment.duration - edge {
            progress = Self.ease((segment.duration - local) / edge)
        } else {
            progress = 1
        }
        let scale = 1 + (segment.scale - 1) * progress
        let center = segment.follows ? (followed(at: time) ?? segment.target) : segment.target
        return ZoomCamera(scale: scale, center: center)
    }

    /// Where the pointer was around `time`, averaged over a fraction of a second so the camera glides.
    func followed(at time: TimeInterval) -> CGPoint? {
        guard let cursor else { return nil }
        var (x, y, count) = (0.0, 0.0, 0.0)
        for step in 0...8 {
            let at = time - 0.3 + 0.4 * Double(step) / 8
            if let point = cursor.position(at: at) {
                x += point.x
                y += point.y
                count += 1
            }
        }
        return count > 0 ? CGPoint(x: x / count, y: y / count) : nil
    }

    /// Cubic ease in and out.
    static func ease(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
