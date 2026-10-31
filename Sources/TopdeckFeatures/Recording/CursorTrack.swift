// SPDX-License-Identifier: MIT
// Adapted from Snapzy (https://github.com/duongductrong/Snapzy) at 77d3d3f: Services/Capture/RecordingMouseTracker.swift,
// Services/Capture/RecordingMetadata.swift (the sample type).
// Copyright (c) 2026, Trong Duong Duc. BSD 3-Clause License; see THIRD_PARTY_NOTICES.md.
import CoreGraphics
import Foundation

/// Where the pointer was during a recording, for the editor's follow-cursor zoom. Positions are fractions of
/// the recorded picture from its top left, and times are seconds into the video, held spans not counted.
/// It's kept beside the recording as a small JSON file and never leaves the Mac.
public struct CursorTrack: Codable, Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        public var time: TimeInterval
        public var x: Double
        public var y: Double

        public init(time: TimeInterval, x: Double, y: Double) {
            self.time = time
            self.x = x
            self.y = y
        }
    }

    public var samples: [Sample]
    /// What the file's audio tracks are, in order: "system", "microphone". Empty when it has none.
    public var audio: [String] = []

    public init(samples: [Sample] = [], audio: [String] = []) {
        self.samples = samples
        self.audio = audio
    }

    /// Samples taken a second, and the least change worth keeping (a fraction of the picture).
    static let rate = 30.0
    static let quiet = 0.0005

    public var isUsable: Bool { samples.count >= 2 }

    /// The pointer at `time`, between the two samples around it; the nearest end outside the track.
    public func position(at time: TimeInterval) -> CGPoint? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if time <= first.time { return CGPoint(x: first.x, y: first.y) }
        if time >= last.time { return CGPoint(x: last.x, y: last.y) }
        var low = 0
        var high = samples.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if samples[middle].time <= time { low = middle } else { high = middle }
        }
        let (a, b) = (samples[low], samples[high])
        let span = b.time - a.time
        let t = span > 0 ? (time - a.time) / span : 0
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Appends a sample unless the pointer has hardly moved since the last one.
    mutating func add(_ sample: Sample) {
        if let last = samples.last, abs(last.x - sample.x) < Self.quiet, abs(last.y - sample.y) < Self.quiet {
            // Keep the time moving on a still pointer, so a long rest isn't read as a gap.
            if sample.time - last.time < 1 { return }
        }
        samples.append(sample)
    }

    /// A point in AppKit's global coordinates as a fraction of `area` (also AppKit's, bottom left), measured
    /// from the area's top left.
    static func fraction(of point: CGPoint, in area: CGRect) -> CGPoint {
        guard area.width > 0, area.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let x = (point.x - area.minX) / area.width
        let y = 1 - (point.y - area.minY) / area.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    // MARK: File

    /// `[time, x, y]` triples, rounded: a minute of a moving pointer is some 30 KB.
    private enum CodingKeys: String, CodingKey { case version, samples, audio }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try container.decode([[Double]].self, forKey: .samples)
        samples = rows.compactMap { $0.count == 3 ? Sample(time: $0[0], x: $0[1], y: $0[2]) : nil }
        audio = try container.decodeIfPresent([String].self, forKey: .audio) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        if !audio.isEmpty { try container.encode(audio, forKey: .audio) }
        func round(_ value: Double, _ places: Double) -> Double { (value * places).rounded() / places }
        try container.encode(
            samples.map { [round($0.time, 1000), round($0.x, 10_000), round($0.y, 10_000)] }, forKey: .samples)
    }

    /// Where a recording's cursor track lives: next to the video, named for it.
    public static func url(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("topdeck-cursor.json")
    }

    /// The recorded track, which may hold no usable pointer (`isUsable`) and only name the audio.
    public static func load(for video: URL) -> CursorTrack? {
        guard let data = try? Data(contentsOf: url(for: video)) else { return nil }
        return try? JSONDecoder().decode(CursorTrack.self, from: data)
    }

    public func save(for video: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.url(for: video), options: .atomic)
    }
}
