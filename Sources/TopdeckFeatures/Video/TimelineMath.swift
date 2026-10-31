// SPDX-License-Identifier: MIT
// Adapted from Snapzy (https://github.com/duongductrong/Snapzy) at 77d3d3f: Features/VideoEditor/Services/VideoEditorTimelineTimeMap.swift.
// Copyright (c) 2026, Trong Duong Duc. BSD 3-Clause License; see THIRD_PARTY_NOTICES.md.
import CoreGraphics
import Foundation

/// Maps between the source's time and the time of what is exported: the trimmed part, with each speed segment
/// played at its rate. One piece of time, one rate, so it is the same arithmetic for the preview, the export and
/// the timeline's readout.
public struct TimelineMap: Equatable, Sendable {
    /// A stretch of the trimmed source played at one rate.
    public struct Span: Equatable, Sendable {
        public var sourceStart: TimeInterval
        public var sourceEnd: TimeInterval
        public var rate: Double
        /// Where it begins in the output.
        public var outputStart: TimeInterval

        public var outputEnd: TimeInterval { outputStart + (sourceEnd - sourceStart) / rate }
    }

    public let trim: ClosedRange<TimeInterval>
    /// Contiguous spans that tile the trim.
    public let spans: [Span]
    public let outputDuration: TimeInterval

    public var isUniform: Bool { spans.allSatisfy { $0.rate == 1 } }

    /// `speeds` may overlap or reach past the trim: they are cut to it, and where two overlap the earlier wins.
    public init(trim: ClosedRange<TimeInterval>, speeds: [SpeedSegment]) {
        self.trim = trim
        var spans: [Span] = []
        var cursor = trim.lowerBound
        var output: TimeInterval = 0
        func add(_ end: TimeInterval, rate: Double) {
            guard end - cursor > 0.0001 else { return }
            spans.append(Span(sourceStart: cursor, sourceEnd: end, rate: rate, outputStart: output))
            output += (end - cursor) / rate
            cursor = end
        }
        for speed in speeds.sorted(by: { $0.start < $1.start }) where speed.rate != 1 {
            let start = max(speed.start, cursor)
            let end = min(speed.end, trim.upperBound)
            guard end - start > 0.0001 else { continue }
            add(start, rate: 1)
            add(end, rate: speed.rate)
        }
        add(trim.upperBound, rate: 1)
        self.spans = spans
        outputDuration = output
    }

    /// The output time of a source time, held to the trim.
    public func toOutput(_ source: TimeInterval) -> TimeInterval {
        let source = min(max(source, trim.lowerBound), trim.upperBound)
        for span in spans where source <= span.sourceEnd {
            return span.outputStart + (source - span.sourceStart) / span.rate
        }
        return outputDuration
    }

    /// The source time of an output time, held to the output's length.
    public func toSource(_ output: TimeInterval) -> TimeInterval {
        let output = min(max(output, 0), outputDuration)
        for span in spans where output <= span.outputEnd {
            return span.sourceStart + (output - span.outputStart) * span.rate
        }
        return trim.upperBound
    }

    /// The rate at a source time; one outside the trim.
    public func rate(atSource time: TimeInterval) -> Double {
        spans.first { time >= $0.sourceStart && time < $0.sourceEnd }?.rate ?? 1
    }
}

/// The timeline's strip, from the first second to the last across `width` points.
public struct TimelineScale: Equatable, Sendable {
    public var duration: TimeInterval
    public var width: CGFloat

    public init(duration: TimeInterval, width: CGFloat) {
        self.duration = max(duration, 0.001)
        self.width = max(width, 1)
    }

    public func x(_ time: TimeInterval) -> CGFloat { CGFloat(min(max(time / duration, 0), 1)) * width }

    public func time(_ x: CGFloat) -> TimeInterval { TimeInterval(min(max(x / width, 0), 1)) * duration }

    /// How many seconds a point is.
    public var secondsPerPoint: TimeInterval { duration / TimeInterval(width) }

    /// The times of the frames a strip of `count` frames shows: the middle of each tile.
    public func frameTimes(count: Int) -> [TimeInterval] {
        guard count > 0 else { return [] }
        return (0..<count).map { (TimeInterval($0) + 0.5) / TimeInterval(count) * duration }
    }

    /// How many tiles of about `tileWidth` points fill the strip.
    public func tiles(of tileWidth: CGFloat) -> Int { max(1, Int((width / max(tileWidth, 1)).rounded())) }
}

/// Moving and stretching the segments of the timeline: they stop at their neighbours and at the trim, and never
/// overlap. One function for zoom and speed alike, on plain ranges.
public enum SegmentDrag {
    public enum Edge: Sendable { case start, end }

    /// Where a segment of `length` seconds starting at `current` may start when dragged to `proposed`: not before
    /// the nearest segment behind it ends, nor past where the next one begins, nor outside `bounds`.
    public static func moved(
        current: ClosedRange<TimeInterval>, to proposed: TimeInterval, among others: [ClosedRange<TimeInterval>],
        within bounds: ClosedRange<TimeInterval>
    ) -> TimeInterval {
        let length = current.upperBound - current.lowerBound
        let (low, high) = limits(of: current, among: others, within: bounds)
        guard high - low >= length else { return current.lowerBound }
        return min(max(proposed, low), high - length)
    }

    /// The segment with one edge dragged to `proposed`, no shorter than `least` and no longer than `most`.
    public static func resized(
        current: ClosedRange<TimeInterval>, edge: Edge, to proposed: TimeInterval,
        among others: [ClosedRange<TimeInterval>], within bounds: ClosedRange<TimeInterval>, least: TimeInterval,
        most: TimeInterval = .infinity
    ) -> ClosedRange<TimeInterval> {
        let (low, high) = limits(of: current, among: others, within: bounds)
        switch edge {
        case .start:
            let start = min(max(proposed, max(low, current.upperBound - most)), current.upperBound - least)
            return start...current.upperBound
        case .end:
            let end = max(min(proposed, min(high, current.lowerBound + most)), current.lowerBound + least)
            return current.lowerBound...end
        }
    }

    /// The room around a segment: from where the nearest one behind it ends (or the bounds start) to where the
    /// nearest one ahead begins (or the bounds end).
    static func limits(
        of current: ClosedRange<TimeInterval>, among others: [ClosedRange<TimeInterval>],
        within bounds: ClosedRange<TimeInterval>
    ) -> (low: TimeInterval, high: TimeInterval) {
        let behind = others.filter { $0.upperBound <= current.lowerBound + 0.0001 }.map(\.upperBound).max()
        let ahead = others.filter { $0.lowerBound >= current.upperBound - 0.0001 }.map(\.lowerBound).min()
        return (max(behind ?? bounds.lowerBound, bounds.lowerBound), min(ahead ?? bounds.upperBound, bounds.upperBound))
    }

    /// The trim handle dragged to `proposed`: the start stays under the end by `least`, and the end over the start.
    public static func trimmed(
        _ trim: ClosedRange<TimeInterval>, edge: Edge, to proposed: TimeInterval, duration: TimeInterval,
        least: TimeInterval
    ) -> ClosedRange<TimeInterval> {
        switch edge {
        case .start: return min(max(proposed, 0), trim.upperBound - least)...trim.upperBound
        case .end: return trim.lowerBound...max(min(proposed, duration), trim.lowerBound + least)
        }
    }
}

public enum TimeText {
    /// "0:42" or "1:02:03", whole seconds, for the readout beside the timeline.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", rest))"
            : "\(minutes):\(String(format: "%02d", rest))"
    }
}
