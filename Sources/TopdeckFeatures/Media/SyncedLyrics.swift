// SPDX-License-Identifier: MIT
import Foundation

/// A track's lyrics with the time each line starts, parsed from LRC.
public struct SyncedLyrics: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        /// Seconds into the track.
        public var time: TimeInterval
        /// Empty for a gap: the line before it ends here.
        public var text: String

        public init(time: TimeInterval, text: String) {
            self.time = time
            self.text = text
        }
    }

    /// What to show at one moment.
    public struct Cursor: Equatable, Sendable {
        /// The line being sung; nil before the first line and in a gap.
        public var current: String?
        /// The next line with words in it.
        public var next: String?
    }

    /// Sorted by time.
    public let lines: [Line]

    public init(lines: [Line]) {
        self.lines = lines.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
    }

    /// Nil when the text has no line with words, so a gap-only file counts as no lyrics.
    public init?(lrc: String) {
        self.init(lines: Self.parse(lrc))
        guard lines.contains(where: { !$0.text.isEmpty }) else { return nil }
    }

    /// The line at `position` seconds, by binary search.
    public func cursor(at position: TimeInterval) -> Cursor {
        // The first line that starts after `position`.
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].time <= position { low = middle + 1 } else { high = middle }
        }
        let current = low > 0 && !lines[low - 1].text.isEmpty ? lines[low - 1].text : nil
        return Cursor(current: current, next: lines[low...].first { !$0.text.isEmpty }?.text)
    }

    // MARK: LRC

    /// `[mm:ss.xx]` stamps, any number before the text, and tags such as `[ar:...]`. `[offset:ms]`
    /// shifts every line: a positive offset makes the lines appear sooner, as the format defines it.
    private static func parse(_ lrc: String) -> [Line] {
        var lines: [Line] = []
        var offset: TimeInterval = 0
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw).drop { $0.isWhitespace }
            var times: [TimeInterval] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = stamp(tag) {
                    times.append(time)
                } else if tag.lowercased().hasPrefix("offset:"),
                    let milliseconds = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces))
                {
                    offset = milliseconds / 1000
                }
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            lines += times.map { Line(time: $0, text: text) }
        }
        return lines.map { Line(time: max(0, $0.time - offset), text: $0.text) }
    }

    /// "01:23", "01:23.5", "01:23.45", "01:23.456" in seconds; the fraction is a decimal, so ".5" is half a second.
    private static func stamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let minutes = Double(parts[0]), parts[0].allSatisfy(\.isASCII),
            parts[0].allSatisfy(\.isNumber)
        else { return nil }
        let seconds = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(seconds.count), seconds[0].allSatisfy(\.isASCII), seconds[0].allSatisfy(\.isNumber),
            let whole = Double(seconds[0])
        else { return nil }
        var fraction = 0.0
        if seconds.count == 2 {
            guard !seconds[1].isEmpty, seconds[1].allSatisfy(\.isASCII), seconds[1].allSatisfy(\.isNumber),
                let value = Double("0." + seconds[1])
            else { return nil }
            fraction = value
        }
        return minutes * 60 + whole + fraction
    }
}
