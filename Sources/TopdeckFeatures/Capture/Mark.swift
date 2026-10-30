// SPDX-License-Identifier: MIT
// The arrowhead's proportions and the stroke hit test are adapted from capcap's Annotations (MIT),
// Copyright (c) 2026 realskyrin; see THIRD_PARTY_NOTICES.md.
import CoreGraphics
import CoreText
import Foundation

/// The tools in the capture editor's toolbar.
enum MarkTool: String, CaseIterable, Identifiable, Sendable {
    case select, rectangle, ellipse, arrow, pen, highlighter, text, pixelate, counter

    var id: Self { self }

    var title: String {
        switch self {
        case .select: "Select"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .arrow: "Arrow"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .text: "Text"
        case .pixelate: "Pixelate"
        case .counter: "Number"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .pixelate: "mosaic"
        case .counter: "1.circle"
        }
    }
}

/// One mark on a capture. Coordinates are the capture's points, from its top left.
struct Mark: Equatable, Sendable {
    enum Shape: Equatable, Sendable {
        case rectangle(CGRect)
        case ellipse(CGRect)
        case arrow(from: CGPoint, to: CGPoint)
        case pen([CGPoint])
        case highlighter([CGPoint])
        case text(String, at: CGPoint)
        case pixelate(CGRect)
        case counter(Int, at: CGPoint)
    }

    var shape: Shape
    var color: RGB
    /// The stroke's width in points. Text and numbers grow with it.
    var width: CGFloat

    /// How close a click has to come to a stroke to pick it.
    static let reach: CGFloat = 6

    /// The mark a drag along `points` makes with `tool`, or nil when the drag is too small to mean
    /// one. Text and numbers aren't dragged: see `Shape.text` and `Shape.counter`.
    static func dragged(_ tool: MarkTool, along points: [CGPoint], color: RGB, width: CGFloat) -> Mark? {
        guard let start = points.first, let end = points.last else { return nil }
        let box = Self.box(around: [start, end])
        let shape: Shape
        switch tool {
        case .rectangle, .ellipse, .pixelate:
            guard box.width >= 3, box.height >= 3 else { return nil }
            shape = tool == .rectangle ? .rectangle(box) : tool == .ellipse ? .ellipse(box) : .pixelate(box)
        case .arrow:
            guard hypot(end.x - start.x, end.y - start.y) >= 6 else { return nil }
            shape = .arrow(from: start, to: end)
        case .pen, .highlighter:
            guard points.count >= 2 else { return nil }
            shape = tool == .pen ? .pen(points) : .highlighter(points)
        case .select, .text, .counter:
            return nil
        }
        return Mark(shape: shape, color: color, width: width)
    }

    /// The text's size in points for a stroke `width`.
    static func fontSize(for width: CGFloat) -> CGFloat { 10 + width * 4 }

    /// A number's circle's diameter for a stroke `width`.
    static func counterDiameter(for width: CGFloat) -> CGFloat { 16 + width * 3 }

    /// The area the mark covers, for picking and for the selection outline.
    var bounds: CGRect {
        switch shape {
        case .rectangle(let rect), .ellipse(let rect):
            return rect.insetBy(dx: -width / 2, dy: -width / 2)
        case .pixelate(let rect):
            return rect
        case .arrow(let start, let end):
            let head = ArrowHead(from: start, to: end, width: width)
            let points = [start, end, head?.left, head?.right].compactMap { $0 }
            return Self.box(around: points).insetBy(dx: -width / 2, dy: -width / 2)
        case .pen(let points):
            return Self.box(around: points).insetBy(dx: -width / 2, dy: -width / 2)
        case .highlighter(let points):
            let half = Self.highlighterWidth(width) / 2
            return Self.box(around: points).insetBy(dx: -half, dy: -half)
        case .text(let string, let origin):
            return CGRect(origin: origin, size: TextLayout(string, fontSize: Self.fontSize(for: width)).size)
        case .counter(_, let center):
            let radius = Self.counterDiameter(for: width) / 2
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    /// Whether a click at `point` picks this mark. Outlines pick on their stroke only, so a click
    /// inside a rectangle reaches the mark under it.
    func contains(_ point: CGPoint) -> Bool {
        let reach = Self.reach + width / 2
        switch shape {
        case .rectangle(let rect):
            let outer = rect.insetBy(dx: -reach, dy: -reach)
            let inner = rect.insetBy(dx: reach, dy: reach)
            return outer.contains(point) && (inner.isEmpty || !inner.contains(point))
        case .ellipse(let rect):
            return Self.ellipseStroke(rect, contains: point, reach: reach)
        case .arrow(let start, let end):
            let head = ArrowHead(from: start, to: end, width: width)
            let headReach = max(reach, (head?.halfWidth ?? 0))
            return Self.distance(from: point, toSegmentFrom: start, to: end) <= reach
                || (head.map { Self.distance(from: point, toSegmentFrom: $0.base, to: end) <= headReach } ?? false)
        case .pen(let points):
            return Self.distance(from: point, toPolyline: points) <= reach
        case .highlighter(let points):
            return Self.distance(from: point, toPolyline: points) <= Self.highlighterWidth(width) / 2 + Self.reach
        case .text, .pixelate, .counter:
            return bounds.insetBy(dx: -Self.reach, dy: -Self.reach).contains(point)
        }
    }

    /// The same mark moved by `delta`.
    func moved(by delta: CGVector) -> Mark {
        func move(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + delta.dx, y: point.y + delta.dy) }
        func move(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: delta.dx, dy: delta.dy) }
        var mark = self
        switch shape {
        case .rectangle(let rect): mark.shape = .rectangle(move(rect))
        case .ellipse(let rect): mark.shape = .ellipse(move(rect))
        case .pixelate(let rect): mark.shape = .pixelate(move(rect))
        case .arrow(let start, let end): mark.shape = .arrow(from: move(start), to: move(end))
        case .pen(let points): mark.shape = .pen(points.map(move))
        case .highlighter(let points): mark.shape = .highlighter(points.map(move))
        case .text(let string, let origin): mark.shape = .text(string, at: move(origin))
        case .counter(let number, let center): mark.shape = .counter(number, at: move(center))
        }
        return mark
    }

    static func highlighterWidth(_ width: CGFloat) -> CGFloat { max(12, width * 5) }

    static func box(around points: [CGPoint]) -> CGRect {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
            let minY = points.map(\.y).min(), let maxY = points.map(\.y).max()
        else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }

    static func distance(from point: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return hypot(point.x - first.x, point.y - first.y) }
        let distances = zip(points, points.dropFirst()).map { distance(from: point, toSegmentFrom: $0, to: $1) }
        return distances.min() ?? .infinity
    }

    /// Whether `point` is within `reach` of an ellipse's outline: inside the ellipse grown by `reach`
    /// and outside the one shrunk by it.
    static func ellipseStroke(_ rect: CGRect, contains point: CGPoint, reach: CGFloat) -> Bool {
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        func inside(_ a: CGFloat, _ b: CGFloat) -> Bool {
            a > 0 && b > 0 && (dx * dx) / (a * a) + (dy * dy) / (b * b) <= 1
        }
        let a = rect.width / 2
        let b = rect.height / 2
        return inside(a + reach, b + reach) && !inside(a - reach, b - reach)
    }
}

/// An arrow's head: a filled triangle at the tip. The head is about seven strokes long, and a short
/// arrow scales its head down so the base never passes the tail.
struct ArrowHead: Equatable {
    let tip: CGPoint
    /// The middle of the triangle's base, where the shaft stops.
    let base: CGPoint
    let left: CGPoint
    let right: CGPoint
    let halfWidth: CGFloat

    init?(from start: CGPoint, to end: CGPoint, width: CGFloat) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        var headLength = max(12, width * 6.5)
        var headWidth = max(12, width * 7.5)
        if length < headLength {
            headWidth *= length / headLength
            headLength = length
        }
        let unit = CGVector(dx: dx / length, dy: dy / length)
        let base = CGPoint(x: end.x - unit.dx * headLength, y: end.y - unit.dy * headLength)
        let half = headWidth / 2
        tip = end
        self.base = base
        left = CGPoint(x: base.x - unit.dy * half, y: base.y + unit.dx * half)
        right = CGPoint(x: base.x + unit.dy * half, y: base.y - unit.dx * half)
        halfWidth = half
    }
}

/// A line of text set with the system font, as the editor and the rendered capture draw it.
struct TextLayout {
    let lines: [CTLine]
    let ascent: CGFloat
    let lineHeight: CGFloat
    let size: CGSize

    init(_ string: String, fontSize: CGFloat, color: CGColor? = nil) {
        let fallback = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil) ?? fallback
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if let color { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        let paragraphs = string.isEmpty ? [""] : string.components(separatedBy: .newlines)
        lines = paragraphs.map { paragraph in
            CTLineCreateWithAttributedString(NSAttributedString(string: paragraph, attributes: attributes))
        }
        ascent = CTFontGetAscent(font)
        lineHeight = (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)).rounded(.up)
        let width = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
        size = CGSize(width: width.rounded(.up), height: lineHeight * CGFloat(lines.count))
    }
}
