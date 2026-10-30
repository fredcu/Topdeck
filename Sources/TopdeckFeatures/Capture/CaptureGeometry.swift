// SPDX-License-Identifier: MIT
import CoreGraphics

/// Where things go on screen during a capture, in points. AppKit's global coordinates start at the
/// bottom left of the main display; ScreenCaptureKit's start at the top left of each display.
enum CaptureGeometry {
    /// The area a drag from `start` to `end` marks out, kept inside `bounds`, on whole points.
    static func selection(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGRect {
        let minX = max(bounds.minX, min(start.x, end.x)).rounded()
        let minY = max(bounds.minY, min(start.y, end.y)).rounded()
        let maxX = min(bounds.maxX, max(start.x, end.x)).rounded()
        let maxY = min(bounds.maxY, max(start.y, end.y)).rounded()
        guard maxX > minX, maxY > minY else { return CGRect(x: minX, y: minY, width: 0, height: 0) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Big enough to be an area rather than a click.
    static func isArea(_ rect: CGRect) -> Bool { rect.width >= 4 && rect.height >= 4 }

    /// An area in AppKit's global coordinates as ScreenCaptureKit's `sourceRect` takes it: from the
    /// top left of the display whose frame is `screen`.
    static func displayLocal(_ rect: CGRect, screen: CGRect) -> CGRect {
        CGRect(x: rect.minX - screen.minX, y: screen.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The pixels an area of `size` points takes at `scale`.
    static func pixels(_ size: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        (max(1, Int((size.width * scale).rounded(.up))), max(1, Int((size.height * scale).rounded(.up))))
    }

    /// A pinned image's first frame: its own size in points, shrunk to fit two thirds of the visible
    /// screen, centered on `center` and kept on screen.
    static func pinFrame(imageSize: CGSize, center: CGPoint, visible: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let fit = min(1, visible.width * 2 / 3 / imageSize.width, visible.height * 2 / 3 / imageSize.height)
        let size = CGSize(width: (imageSize.width * fit).rounded(), height: (imageSize.height * fit).rounded())
        let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        return kept(CGRect(origin: origin, size: size), inside: visible)
    }

    /// A pinned image's frame zoomed by `factor` around its center: from a tenth of the image's size
    /// (but never under 40 points across) to four times it.
    static func zoomed(_ frame: CGRect, by factor: CGFloat, imageSize: CGSize) -> CGRect {
        guard frame.width > 0, imageSize.width > 0, factor > 0 else { return frame }
        let smallest = max(imageSize.width / 10, min(40, imageSize.width)) / frame.width
        let largest = imageSize.width * 4 / frame.width
        let scale = min(largest, max(smallest, factor))
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        return CGRect(origin: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2), size: size)
    }

    /// `frame` moved the least it takes to lie inside `bounds`; a frame larger than `bounds` keeps its
    /// top left corner in view.
    static func kept(_ frame: CGRect, inside bounds: CGRect) -> CGRect {
        var origin = frame.origin
        origin.x = max(bounds.minX, min(origin.x, bounds.maxX - frame.width))
        origin.y = min(bounds.maxY - frame.height, max(origin.y, bounds.minY))
        if frame.height > bounds.height { origin.y = bounds.maxY - frame.height }
        return CGRect(origin: origin, size: frame.size)
    }
}
