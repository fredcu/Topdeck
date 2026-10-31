// SPDX-License-Identifier: MIT
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// A capture kept in Topdeck's Captures folder, as the Tools screen lists it. Screenshots are kept
/// there; recordings will join them, so a capture's kind and thumbnail are not tied to pictures.
public struct RecentCapture: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case png, mp4, gif

        init?(pathExtension: String) {
            self.init(rawValue: pathExtension.lowercased())
        }

        /// The badge on its thumbnail.
        public var badge: String { rawValue.uppercased() }
        public var isVideo: Bool { self == .mp4 }
    }

    public let url: URL
    public let date: Date
    public let kind: Kind

    public var id: URL { url }
}

enum CaptureLibrary {
    /// The `limit` newest captures in `folder`: screenshots, recordings and GIFs, newest first.
    static func recent(in folder: URL, limit: Int) -> [RecentCapture] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        let captures = files.compactMap { url -> RecentCapture? in
            guard let kind = RecentCapture.Kind(pathExtension: url.pathExtension) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let date = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            return RecentCapture(url: url, date: date, kind: kind)
        }
        return Array(captures.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// "18:52" for today's, "Yesterday", else "28 Oct".
    static func timeLabel(
        _ date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(
                Date.FormatStyle(
                    date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        return date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day())
    }

    /// A thumbnail at most `maxPixel` across: a picture's own, or a recording's first frame.
    static func thumbnail(of capture: RecentCapture, maxPixel: Int) async -> CaptureImage? {
        if capture.kind.isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: capture.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            return (try? await generator.image(at: .zero).image).map { CaptureImage(image: $0, scale: 1) }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithURL(capture.url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map {
            CaptureImage(image: $0, scale: 1)
        }
    }

    /// A kept screenshot back as an image to edit, at the scale it was taken.
    static func image(at url: URL) -> CaptureImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        return CaptureImage(image: image, scale: max(1, dpi / 72))
    }
}

/// Thumbnails kept in memory, so a capture isn't decoded again each time the Tools screen opens. They are
/// made off the main thread.
@MainActor
final class CaptureThumbnails {
    private final class Box {
        let image: CaptureImage
        init(_ image: CaptureImage) { self.image = image }
    }

    private let cache: NSCache<NSURL, Box> = {
        let cache = NSCache<NSURL, Box>()
        cache.countLimit = 32
        return cache
    }()

    func cached(_ capture: RecentCapture) -> CaptureImage? { cache.object(forKey: capture.url as NSURL)?.image }

    func image(for capture: RecentCapture, maxPixel: Int) async -> CaptureImage? {
        if let kept = cached(capture) { return kept }
        let made = await Task.detached(priority: .utility) {
            await CaptureLibrary.thumbnail(of: capture, maxPixel: maxPixel)
        }.value
        if let made { cache.setObject(Box(made), forKey: capture.url as NSURL) }
        return made
    }

    func forget(_ capture: RecentCapture) { cache.removeObject(forKey: capture.url as NSURL) }
}
