// SPDX-License-Identifier: MIT
import Foundation

/// A colour in sRGB, small enough to travel in an `Activity` from a feature to the closed notch.
public struct ActivityTint: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// The four bars beside the camera while music plays. They move to a made-up pattern, not to the audio:
/// each bar's height is two sines of different speeds added together, so the four never move together and
/// the pattern doesn't repeat quickly. Nothing is captured or measured, which is what lets them cost almost
/// nothing. Pure, so the shape is tested without drawing.
public enum MusicBars {
    public static let count = 4
    /// Points: each bar's width, the gap between bars, and the tallest and shortest height.
    public static let barWidth = 3.0
    public static let gap = 2.0
    public static let maxHeight = 14.0
    public static let minHeight = 3.0
    /// The bars' total width.
    public static let width = Double(count) * barWidth + Double(count - 1) * gap

    /// How fast each bar's two sines turn, in radians a second, and where in their turn they start.
    private static let fast: [Double] = [5.3, 6.9, 4.4, 7.7]
    private static let slow: [Double] = [2.1, 1.7, 2.9, 2.3]
    private static let phase: [Double] = [0, 1.9, 4.1, 2.6]

    /// Whether the bars need a timeline: only while the music plays and Reduce Motion is off. Otherwise they
    /// are drawn once and nothing wakes up.
    public static func animates(playing: Bool, reduceMotion: Bool) -> Bool { playing && !reduceMotion }

    /// Paused: low and still.
    public static let resting: [Double] = [4, 6, 5, 4]
    /// Playing with Reduce Motion on: a still shape in the middle of the range.
    public static let still: [Double] = [7, 11, 9, 8]

    /// The height of `bar` (0 to 3) `time` seconds in, between `minHeight` and `maxHeight`. The faster sine
    /// carries 60% of the swing and the slower 40%.
    public static func height(bar: Int, at time: TimeInterval) -> Double {
        guard (0..<count).contains(bar) else { return minHeight }
        let swing = 0.6 * sin(time * fast[bar] + phase[bar]) + 0.4 * sin(time * slow[bar] + phase[bar] * 0.5)
        return minHeight + (maxHeight - minHeight) * (swing + 1) / 2
    }

    /// All four heights at `time`.
    public static func heights(at time: TimeInterval) -> [Double] {
        (0..<count).map { height(bar: $0, at: time) }
    }
}
