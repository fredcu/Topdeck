// SPDX-License-Identifier: MIT
// Adapted from Snapzy (https://github.com/duongductrong/Snapzy) at 77d3d3f: Features/VideoEditor/Models/VideoEditorZoomSegment.swift,
// Features/VideoEditor/Models/VideoEditorSpeedSegment.swift.
// Copyright (c) 2026, Trong Duong Duc. BSD 3-Clause License; see THIRD_PARTY_NOTICES.md.
import CoreGraphics
import Foundation

/// A stretch of the video that is zoomed in: from `start` for `duration` source seconds, `scale` times, on the
/// pointer (where it was recorded) or on a target picked by hand.
public struct ZoomSegment: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var start: TimeInterval
    public var duration: TimeInterval
    public var scale: Double
    /// Follows the recorded pointer. Without a recording of it, the target is used.
    public var follows: Bool
    /// The manual target, as fractions of the picture from its top left.
    public var target: CGPoint

    public static let minimumDuration: TimeInterval = 0.5
    public static let maximumDuration: TimeInterval = 30
    public static let defaultDuration: TimeInterval = 2
    public static let scaleRange: ClosedRange<Double> = 1...4
    public static let defaultScale = 1.8

    public init(
        id: UUID = UUID(), start: TimeInterval, duration: TimeInterval = defaultDuration, scale: Double = defaultScale,
        follows: Bool = false, target: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) {
        self.id = id
        self.start = max(0, start)
        self.duration = min(max(duration, Self.minimumDuration), Self.maximumDuration)
        self.scale = min(max(scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        self.follows = follows
        self.target = CGPoint(x: min(max(target.x, 0), 1), y: min(max(target.y, 0), 1))
    }

    public var end: TimeInterval { start + duration }
}

/// A stretch of the video played faster (a timelapse) or slower, in source seconds.
public struct SpeedSegment: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var start: TimeInterval
    public var duration: TimeInterval
    public var rate: Double

    public static let presets: [Double] = [0.25, 0.5, 1, 2, 4, 8]
    public static let rateRange: ClosedRange<Double> = 0.25...8
    public static let defaultRate = 2.0
    public static let minimumDuration: TimeInterval = 0.5
    public static let defaultDuration: TimeInterval = 3

    public init(
        id: UUID = UUID(), start: TimeInterval, duration: TimeInterval = defaultDuration, rate: Double = defaultRate
    ) {
        self.id = id
        self.start = max(0, start)
        self.duration = max(duration, Self.minimumDuration)
        self.rate = min(max(rate, Self.rateRange.lowerBound), Self.rateRange.upperBound)
    }

    public var end: TimeInterval { start + duration }
}

/// The part of the picture that is kept, as fractions of it from its top left.
public struct CropRegion: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public static let full = CropRegion(x: 0, y: 0, width: 1, height: 1)
    /// The least that is kept on a side: a tenth of the picture.
    public static let minimumSide = 0.1

    public init(x: Double, y: Double, width: Double, height: Double) {
        let w = min(max(width, Self.minimumSide), 1)
        let h = min(max(height, Self.minimumSide), 1)
        self.width = w
        self.height = h
        self.x = min(max(x, 0), 1 - w)
        self.y = min(max(y, 0), 1 - h)
    }

    public var isFull: Bool { x <= 0.0005 && y <= 0.0005 && width >= 0.999 && height >= 0.999 }
    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// What lies behind the video when it is inset. `none` leaves it filling the frame.
public enum BackgroundFill: Codable, Equatable, Hashable, Sendable {
    case none
    /// From the top left corner to the bottom right, in 0xRRGGBB.
    case gradient(from: UInt32, to: UInt32)
    case solid(UInt32)

    /// The choices the editor offers, after "none", as the board has them.
    public static let presets: [BackgroundFill] = [
        .gradient(from: 0x2B4C7E, to: 0xC86A7A), .gradient(from: 0x1E8E7E, to: 0x2B4C7E),
        .gradient(from: 0xB5562B, to: 0xA8325E), .solid(0x232936),
    ]

    public var isNone: Bool { self == .none }
}

/// One audio track of the recording: how loud, or off.
public struct AudioTrackSetting: Codable, Equatable, Hashable, Sendable {
    public var volume = 1.0
    public var muted = false

    public static let volumeRange: ClosedRange<Double> = 0...2

    public init(volume: Double = 1, muted: Bool = false) {
        self.volume = min(max(volume, Self.volumeRange.lowerBound), Self.volumeRange.upperBound)
        self.muted = muted
    }

    /// What the export applies.
    public var gain: Float { muted ? 0 : Float(volume) }
}

/// Everything the editor changes, and nothing of the video itself: the source stays as it was. It is kept as a
/// small JSON file beside the video, so reopening brings it back. Times are seconds of the source.
public struct VideoEdit: Codable, Equatable, Sendable {
    public var trimStart: TimeInterval = 0
    /// Nil keeps to the end.
    public var trimEnd: TimeInterval?
    public var zooms: [ZoomSegment] = []
    public var speeds: [SpeedSegment] = []
    public var crop = CropRegion.full
    public var background = BackgroundFill.none
    /// Space around the video, and the rounding of its corners, in units of a frame a thousand wide: they scale
    /// with the picture, so the preview and the export agree at any size.
    public var padding = 48.0
    public var corners = 12.0
    /// By audio track, in the file's order; a track not listed is as it was recorded.
    public var audio: [AudioTrackSetting] = []
    public var export = ExportSettings()

    public static let paddingRange: ClosedRange<Double> = 0...200
    public static let cornersRange: ClosedRange<Double> = 0...60
    /// The least that is left after a trim.
    public static let minimumLength: TimeInterval = 0.5

    public init() {}

    /// A file written by an older or newer Topdeck may lack a key: it takes its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trimStart = try c.decodeIfPresent(TimeInterval.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(TimeInterval.self, forKey: .trimEnd)
        zooms = try c.decodeIfPresent([ZoomSegment].self, forKey: .zooms) ?? []
        speeds = try c.decodeIfPresent([SpeedSegment].self, forKey: .speeds) ?? []
        crop = try c.decodeIfPresent(CropRegion.self, forKey: .crop) ?? .full
        background = try c.decodeIfPresent(BackgroundFill.self, forKey: .background) ?? .none
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? 48
        corners = try c.decodeIfPresent(Double.self, forKey: .corners) ?? 12
        audio = try c.decodeIfPresent([AudioTrackSetting].self, forKey: .audio) ?? []
        export = try c.decodeIfPresent(ExportSettings.self, forKey: .export) ?? ExportSettings()
    }

    /// Nothing changed: no sidecar is kept for it.
    public var isUnchanged: Bool { self == VideoEdit() }

    /// The part of a video `duration` long that is kept.
    public func trim(duration: TimeInterval) -> ClosedRange<TimeInterval> {
        let length = max(duration, 0)
        let floorLength = min(Self.minimumLength, length)
        let start = min(max(trimStart, 0), max(length - floorLength, 0))
        let end = min(max(trimEnd ?? length, start + floorLength), length)
        return start...max(end, start)
    }

    /// Whether the video is framed in a background: something behind it and room for it.
    public var hasBackground: Bool { !background.isNone && padding > 0 }

    public func audioSetting(_ index: Int) -> AudioTrackSetting { index < audio.count ? audio[index] : .init() }

    public mutating func setAudio(_ setting: AudioTrackSetting, at index: Int) {
        while audio.count <= index { audio.append(.init()) }
        audio[index] = setting
        while audio.last == AudioTrackSetting() { audio.removeLast() }
    }

    // MARK: Segments

    /// Adds a zoom at `time`, as long as it can be before the next one or the end of the trim. Nil when there
    /// is no room for one.
    @discardableResult
    public mutating func addZoom(at time: TimeInterval, duration: TimeInterval, follows: Bool) -> UUID? {
        guard
            let slot = Self.slot(
                at: time, wanted: ZoomSegment.defaultDuration, least: ZoomSegment.minimumDuration,
                among: zooms.map { $0.start...$0.end }, within: trim(duration: duration))
        else { return nil }
        let zoom = ZoomSegment(start: slot.lowerBound, duration: slot.upperBound - slot.lowerBound, follows: follows)
        zooms.append(zoom)
        zooms.sort { $0.start < $1.start }
        return zoom.id
    }

    @discardableResult
    public mutating func addSpeed(at time: TimeInterval, duration: TimeInterval) -> UUID? {
        guard
            let slot = Self.slot(
                at: time, wanted: SpeedSegment.defaultDuration, least: SpeedSegment.minimumDuration,
                among: speeds.map { $0.start...$0.end }, within: trim(duration: duration))
        else { return nil }
        let speed = SpeedSegment(start: slot.lowerBound, duration: slot.upperBound - slot.lowerBound)
        speeds.append(speed)
        speeds.sort { $0.start < $1.start }
        return speed.id
    }

    /// The room for a segment `wanted` long starting at `time`: it ends at the next segment or the trim's end, and
    /// when that leaves less than `least`, it is moved back to end there instead. Nil when even that doesn't fit.
    static func slot(
        at time: TimeInterval, wanted: TimeInterval, least: TimeInterval, among others: [ClosedRange<TimeInterval>],
        within bounds: ClosedRange<TimeInterval>
    ) -> ClosedRange<TimeInterval>? {
        let start = min(max(time, bounds.lowerBound), bounds.upperBound)
        if others.contains(where: { $0.lowerBound < start && start < $0.upperBound }) { return nil }
        let next = others.map(\.lowerBound).filter { $0 >= start }.min() ?? bounds.upperBound
        let end = min(start + wanted, next, bounds.upperBound)
        if end - start >= least { return start...end }
        // Too close to the next one or the end: end where that is, if there is room behind.
        let previous = others.map(\.upperBound).filter { $0 <= start }.max() ?? bounds.lowerBound
        let begin = max(end - wanted, previous, bounds.lowerBound)
        return end - begin >= least ? begin...end : nil
    }
}

// MARK: Export settings

public enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case mp4, gif

    public var title: String { rawValue.uppercased() }
}

/// The longest a picture may be, in pixels, on each side: it is shrunk to fit, never enlarged.
public enum ExportSize: String, Codable, CaseIterable, Sendable {
    case original, p1080, p720, p480

    public var title: String {
        switch self {
        case .original: "Original"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        }
    }

    /// The box the picture has to fit, nil for its own size.
    var box: CGSize? {
        switch self {
        case .original: nil
        case .p1080: CGSize(width: 1920, height: 1080)
        case .p720: CGSize(width: 1280, height: 720)
        case .p480: CGSize(width: 854, height: 480)
        }
    }
}

public enum ExportQuality: String, Codable, CaseIterable, Sendable {
    case high, medium, low

    public var title: String { rawValue.capitalized }

    /// Bits per pixel per frame of an MP4, before its floor and cap.
    var bitsPerPixel: Double {
        switch self {
        case .high: 0.2
        case .medium: 0.12
        case .low: 0.07
        }
    }

    /// Frames a second of a GIF: smoother or smaller.
    var gifFramesPerSecond: Double {
        switch self {
        case .high: 20
        case .medium: 12
        case .low: 8
        }
    }
}

public struct ExportSettings: Codable, Equatable, Sendable {
    public var format = ExportFormat.mp4
    public var size = ExportSize.original
    public var quality = ExportQuality.high

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(ExportFormat.self, forKey: .format) ?? .mp4
        size = try c.decodeIfPresent(ExportSize.self, forKey: .size) ?? .original
        quality = try c.decodeIfPresent(ExportQuality.self, forKey: .quality) ?? .high
    }
}

/// The edit, kept as a small JSON file beside the video it belongs to: `<name>.topdeck-edit.json`. Reopening the
/// video brings it back. The video itself is never written.
public enum EditSidecar {
    private struct File: Codable {
        var version = 1
        /// The video's length when the edit was made: a different video under the same name is not edited.
        var duration: TimeInterval
        var edit: VideoEdit
    }

    public static func url(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("topdeck-edit.json")
    }

    /// The saved edit of `video`, which is `duration` long now; nil when there is none, it can't be read, or the
    /// video has changed since.
    public static func load(for video: URL, duration: TimeInterval) -> VideoEdit? {
        guard let data = try? Data(contentsOf: url(for: video)),
            let file = try? JSONDecoder().decode(File.self, from: data), abs(file.duration - duration) < 0.5
        else { return nil }
        return file.edit
    }

    /// Writes the edit, or removes the file when there is nothing in it.
    public static func save(_ edit: VideoEdit, for video: URL, duration: TimeInterval) throws {
        let location = url(for: video)
        guard !edit.isUnchanged else {
            try? FileManager.default.removeItem(at: location)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(File(duration: duration, edit: edit)).write(to: location, options: .atomic)
    }
}
