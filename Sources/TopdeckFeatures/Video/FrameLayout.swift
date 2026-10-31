// SPDX-License-Identifier: MIT
import CoreGraphics
import Foundation

/// How the edited picture is laid out in pixels, from the source's size and the edit: what is cropped, the
/// canvas with its padding, and where the video sits on it. All rectangles start at the top left.
public struct FrameLayout: Equatable, Sendable {
    /// The kept part of the source, in its pixels.
    public let crop: CGRect
    /// The picture the export makes, even in both sides.
    public let canvas: CGSize
    /// Where the video sits on the canvas.
    public let content: CGRect
    /// The rounding of the video's corners, in canvas pixels; zero without a background.
    public let cornerRadius: CGFloat

    /// `box` is the largest the canvas may be: it is shrunk to fit, never enlarged, and turned to fit a tall one.
    public init(source: CGSize, edit: VideoEdit, box: CGSize? = nil) {
        let region = edit.crop
        let sourceWidth = max(source.width, 2)
        let sourceHeight = max(source.height, 2)
        // Whole even pixels, so the crop doesn't cut a pixel in half.
        func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded() * 2) }
        let cropWidth = min(even(region.width * sourceWidth), sourceWidth.rounded(.down))
        let cropHeight = min(even(region.height * sourceHeight), sourceHeight.rounded(.down))
        let cropX = min((region.x * sourceWidth).rounded(), sourceWidth - cropWidth)
        let cropY = min((region.y * sourceHeight).rounded(), sourceHeight - cropHeight)
        crop = CGRect(x: max(cropX, 0), y: max(cropY, 0), width: cropWidth, height: cropHeight)

        // Padding and corners are units of a frame a thousand wide.
        let framed = edit.hasBackground
        let padding = framed ? CGFloat(edit.padding) / 1000 * cropWidth : 0
        let full = CGSize(width: cropWidth + 2 * padding, height: cropHeight + 2 * padding)
        var fit: CGFloat = 1
        if var box {
            if full.height > full.width { box = CGSize(width: box.height, height: box.width) }
            fit = min(1, box.width / full.width, box.height / full.height)
        }
        let size = CGSize(width: even(full.width * fit), height: even(full.height * fit))
        canvas = size
        let inset = padding * fit
        // The even rounding of the canvas is shared out, so the video fills what the padding leaves.
        content = CGRect(
            x: inset, y: inset, width: max(size.width - 2 * inset, 2), height: max(size.height - 2 * inset, 2))
        cornerRadius =
            framed ? min(CGFloat(edit.corners) / 1000 * cropWidth * fit, min(content.width, content.height) / 2) : 0
    }

    /// The largest an export of `edit` can be: the preset's box, with a GIF never above 720p.
    public static func box(for settings: ExportSettings) -> CGSize? {
        if settings.format == .gif, settings.size == .original { return ExportSize.p720.box }
        return settings.size.box
    }
}

/// What an export has to do, worked out from the source and the edit: nothing here touches a file.
public struct ExportPlan: Equatable, Sendable {
    public var layout: FrameLayout
    public var map: TimelineMap
    public var settings: ExportSettings
    /// The audio tracks that are kept, by their place in the file, with what they are multiplied by.
    public var audio: [(track: Int, gain: Float)]
    /// Frames a second of the picture the export makes.
    public var framesPerSecond: Double
    public var bitrate: Int

    /// `framesPerSecond` is the source's own rate (30 when it doesn't say).
    public init(
        source: CGSize, duration: TimeInterval, sourceFramesPerSecond: Double, audioTracks: Int, edit: VideoEdit
    ) {
        settings = edit.export
        layout = FrameLayout(source: source, edit: edit, box: FrameLayout.box(for: edit.export))
        map = TimelineMap(trim: edit.trim(duration: duration), speeds: edit.speeds)
        audio =
            settings.format == .gif
            ? []
            : (0..<audioTracks).compactMap { index in
                let setting = edit.audioSetting(index)
                return setting.gain > 0 ? (index, setting.gain) : nil
            }
        let canvasPixels = Double(layout.canvas.width * layout.canvas.height)
        if settings.format == .gif {
            // A GIF keeps every frame in memory until it is written: fewer for a big or long one.
            let wanted = settings.quality.gifFramesPerSecond
            let budget = 300_000_000.0 / max(canvasPixels * max(map.outputDuration, 0.1), 1)
            framesPerSecond = max(5, min(wanted, budget))
            bitrate = 0
        } else {
            framesPerSecond = min(max(sourceFramesPerSecond > 0 ? sourceFramesPerSecond : 30, 15), 60)
            let wanted = canvasPixels * framesPerSecond * settings.quality.bitsPerPixel
            bitrate = Int(min(max(wanted, 800_000), 60_000_000).rounded())
        }
    }

    public static func == (lhs: ExportPlan, rhs: ExportPlan) -> Bool {
        lhs.layout == rhs.layout && lhs.map == rhs.map && lhs.settings == rhs.settings
            && lhs.audio.map(\.track) == rhs.audio.map(\.track) && lhs.audio.map(\.gain) == rhs.audio.map(\.gain)
            && lhs.framesPerSecond == rhs.framesPerSecond && lhs.bitrate == rhs.bitrate
    }

    /// Frames in the output.
    public var frameCount: Int { max(1, Int((map.outputDuration * framesPerSecond).rounded(.up))) }
}

public enum ExportNaming {
    /// Beside the source, named for it and the edit, and never the source's own name or one that is taken:
    /// "Screen Recording … edited.mp4", then "… edited 2.mp4".
    public static func destination(
        for source: URL, format: ExportFormat, in folder: URL? = nil,
        exists: (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path)
        }
    ) -> URL {
        let directory = folder ?? source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let ext = format == .mp4 ? "mp4" : "gif"
        var url = directory.appending(path: "\(base) edited.\(ext)")
        var number = 2
        while exists(url) || exists(URL(filePath: url.path + ".partial"))
            || url.standardizedFileURL == source.standardizedFileURL
        {
            url = directory.appending(path: "\(base) edited \(number).\(ext)")
            number += 1
        }
        return url
    }
}

/// Dragging the crop rectangle on the preview of the whole picture.
public enum CropDrag {
    public enum Handle: Sendable {
        case move, topLeft, topRight, bottomLeft, bottomRight
    }

    /// `crop` dragged by `delta`, a fraction of the picture, on `handle`: moving keeps its size and stays inside; a
    /// corner moves with the pointer and leaves the opposite corner where it is, no smaller than the least.
    public static func dragged(_ crop: CropRegion, handle: Handle, by delta: CGSize) -> CropRegion {
        var (left, top, right, bottom) = (crop.x, crop.y, crop.x + crop.width, crop.y + crop.height)
        let least = CropRegion.minimumSide
        switch handle {
        case .move:
            let x = min(max(crop.x + delta.width, 0), 1 - crop.width)
            let y = min(max(crop.y + delta.height, 0), 1 - crop.height)
            return CropRegion(x: x, y: y, width: crop.width, height: crop.height)
        case .topLeft:
            left = min(max(left + delta.width, 0), right - least)
            top = min(max(top + delta.height, 0), bottom - least)
        case .topRight:
            right = max(min(right + delta.width, 1), left + least)
            top = min(max(top + delta.height, 0), bottom - least)
        case .bottomLeft:
            left = min(max(left + delta.width, 0), right - least)
            bottom = max(min(bottom + delta.height, 1), top + least)
        case .bottomRight:
            right = max(min(right + delta.width, 1), left + least)
            bottom = max(min(bottom + delta.height, 1), top + least)
        }
        return CropRegion(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The largest rectangle of `aspect` (width over height) that fits a picture of `source` pixels, in its middle.
    public static func centered(aspect: Double, in source: CGSize) -> CropRegion {
        guard aspect > 0, source.width > 0, source.height > 0 else { return .full }
        let picture = Double(source.width / source.height)
        let (width, height) = aspect >= picture ? (1.0, picture / aspect) : (aspect / picture, 1.0)
        return CropRegion(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }
}
