// SPDX-License-Identifier: MIT
import CoreGraphics
import CoreText

/// Draws marks on a capture. The editor draws them on screen and the result burns them into the
/// image, through the same code, so what's copied is what was seen.
enum MarkRenderer {
    /// The capture with its marks burned in, at the capture's full resolution. `scale` is the
    /// capture's pixels per point.
    static func render(_ image: CGImage, marks: [Mark], scale: CGFloat) -> CGImage? {
        guard !marks.isEmpty else { return image }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: info)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // Marks are in points from the top left.
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: scale, y: -scale)
        for mark in marks { draw(mark, in: context, source: image, scale: scale) }
        return context.makeImage()
    }

    /// Draws `mark` in a context whose space is the capture's points from the top left, y down.
    /// `source` is the capture itself, which pixelation reads.
    static func draw(_ mark: Mark, in context: CGContext, source: CGImage, scale: CGFloat) {
        let color = mark.color.cgColor
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(mark.width)
        switch mark.shape {
        case .rectangle(let rect):
            context.stroke(rect)
        case .ellipse(let rect):
            context.strokeEllipse(in: rect)
        case .arrow(let start, let end):
            guard let head = ArrowHead(from: start, to: end, width: mark.width) else { return }
            context.strokeLineSegments(between: [start, head.base])
            context.addLines(between: [head.tip, head.left, head.right])
            context.closePath()
            context.fillPath()
        case .pen(let points):
            context.addLines(between: points)
            context.strokePath()
        case .highlighter(let points):
            context.setStrokeColor(color.copy(alpha: 0.4) ?? color)
            context.setLineWidth(Mark.highlighterWidth(mark.width))
            context.setLineCap(.butt)
            context.addLines(between: points)
            context.strokePath()
        case .text(let string, let origin):
            let layout = TextLayout(string, fontSize: Mark.fontSize(for: mark.width), color: color)
            draw(layout, at: origin, in: context)
        case .pixelate(let rect):
            pixelate(rect, of: source, scale: scale, in: context)
        case .counter(let number, let center):
            let diameter = Mark.counterDiameter(for: mark.width)
            let corner = CGPoint(x: center.x - diameter / 2, y: center.y - diameter / 2)
            context.fillEllipse(in: CGRect(origin: corner, size: CGSize(width: diameter, height: diameter)))
            let white = CGColor(gray: 1, alpha: 1)
            let layout = TextLayout(String(number), fontSize: diameter * 0.55, color: white)
            let origin = CGPoint(x: center.x - layout.size.width / 2, y: center.y - layout.size.height / 2)
            draw(layout, at: origin, in: context)
        }
    }

    /// Text in a y-down context: Core Text draws y-up, so each line is flipped back around its
    /// baseline.
    static func draw(_ layout: TextLayout, at origin: CGPoint, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (index, line) in layout.lines.enumerated() {
            let baseline = origin.y + CGFloat(index) * layout.lineHeight + layout.ascent
            context.textPosition = CGPoint(x: origin.x, y: baseline)
            CTLineDraw(line, context)
        }
    }

    /// Covers `rect` with blocks of the capture's own colours, about 12 points across, so what was
    /// there can't be read back.
    static func pixelate(_ rect: CGRect, of source: CGImage, scale: CGFloat, in context: CGContext) {
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let pixels = rect.applying(CGAffineTransform(scaleX: scale, y: scale)).integral.intersection(bounds)
        guard !pixels.isEmpty, let crop = source.cropping(to: pixels) else { return }
        let block: CGFloat = 12
        let columns = max(1, Int((rect.width / block).rounded(.up)))
        let rows = max(1, Int((rect.height / block).rounded(.up)))
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard
            let small = CGContext(
                data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: info)
        else { return }
        small.interpolationQuality = .high
        small.draw(crop, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        guard let blocks = small.makeImage() else { return }
        let shown = pixels.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        context.interpolationQuality = .none
        drawUpright(blocks, in: shown, context: context)
    }

    /// Draws an image the right way up in a y-down context.
    static func drawUpright(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
    }
}

extension RGB {
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    /// The editor's colours.
    static let markColors = [
        RGB(red: 1, green: 0.23, blue: 0.19),
        RGB(red: 1, green: 0.8, blue: 0),
        RGB(red: 0.2, green: 0.78, blue: 0.35),
        RGB(red: 0, green: 0.48, blue: 1),
        RGB(red: 1, green: 1, blue: 1),
        RGB(red: 0, green: 0, blue: 0),
    ]
}
