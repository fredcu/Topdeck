// SPDX-License-Identifier: MIT
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing

@testable import TopdeckFeatures

struct CaptureGeometryTests {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func aDragInAnyDirectionMakesTheSameArea() {
        let down = CaptureGeometry.selection(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 110, y: 70), in: screen)
        let up = CaptureGeometry.selection(from: CGPoint(x: 110, y: 70), to: CGPoint(x: 10, y: 20), in: screen)
        #expect(down == CGRect(x: 10, y: 20, width: 100, height: 50))
        #expect(up == down)
    }

    @Test func theAreaStaysOnTheScreenOnWholePoints() {
        let area = CaptureGeometry.selection(from: CGPoint(x: -40, y: 900.4), to: CGPoint(x: 99.6, y: 1100), in: screen)
        #expect(area == CGRect(x: 0, y: 900, width: 100, height: 82))
    }

    @Test func onlyTheCapturesOwnListedWindowsAreExcluded() {
        // 7 is a pinned note, which stays in; 11 is the overlay; 20 isn't on screen any more.
        let excluded = CaptureGeometry.excludedWindows([11, 20], available: [7, 11, 30])
        #expect(excluded == [11])
        #expect(CaptureGeometry.excludedWindows([-1, 0], available: [0, 7]).isEmpty)
        #expect(CaptureGeometry.excludedWindows([], available: [7]).isEmpty)
    }

    @Test func aClickIsNotAnArea() {
        let click = CaptureGeometry.selection(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 7, y: 5), in: screen)
        #expect(!CaptureGeometry.isArea(click))
        #expect(CaptureGeometry.isArea(CGRect(x: 0, y: 0, width: 4, height: 4)))
    }

    /// AppKit counts from the bottom left of the main display; ScreenCaptureKit from the top left of
    /// each display.
    @Test func areasBecomeDisplayLocalFromTheTop() {
        let local = CaptureGeometry.displayLocal(CGRect(x: 100, y: 800, width: 200, height: 100), screen: screen)
        #expect(local == CGRect(x: 100, y: 82, width: 200, height: 100))
        // A display to the right of the main one, and taller.
        let external = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        let there = CaptureGeometry.displayLocal(CGRect(x: 1612, y: 1140, width: 50, height: 40), screen: external)
        #expect(there == CGRect(x: 100, y: 60, width: 50, height: 40))
    }

    @Test func pixelsRoundUp() {
        let pixels = CaptureGeometry.pixels(CGSize(width: 100.5, height: 10), scale: 2)
        #expect(pixels.width == 201 && pixels.height == 20)
        let none = CaptureGeometry.pixels(.zero, scale: 2)
        #expect(none.width == 1 && none.height == 1)
    }

    @Test func aPinFitsTwoThirdsOfTheScreenAndStaysOnIt() {
        let visible = CGRect(x: 0, y: 0, width: 1500, height: 900)
        let middle = CGPoint(x: 750, y: 450)
        let photo = CGSize(width: 300, height: 200)
        let small = CaptureGeometry.pinFrame(imageSize: photo, center: middle, visible: visible)
        #expect(small == CGRect(x: 600, y: 350, width: 300, height: 200))
        let page = CGSize(width: 400, height: 6000)
        let tall = CaptureGeometry.pinFrame(imageSize: page, center: middle, visible: visible)
        #expect(tall.height == 600 && tall.width == 40)
        let corner = CaptureGeometry.pinFrame(imageSize: photo, center: .zero, visible: visible)
        #expect(corner.origin == .zero)
    }

    @Test func zoomKeepsTheCenterAndStaysInBounds() {
        let image = CGSize(width: 400, height: 200)
        let frame = CGRect(x: 100, y: 100, width: 400, height: 200)
        let bigger = CaptureGeometry.zoomed(frame, by: 1.5, imageSize: image)
        #expect(bigger.width == 600 && bigger.height == 300)
        #expect(bigger.midX == frame.midX && bigger.midY == frame.midY)
        #expect(CaptureGeometry.zoomed(frame, by: 100, imageSize: image).width == 1600, "at most four times")
        #expect(CaptureGeometry.zoomed(frame, by: 0.001, imageSize: image).width == 40, "at least 40 points")
    }

    @Test func aFrameIsPulledBackOnScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let edge = CaptureGeometry.kept(CGRect(x: 90, y: -5, width: 20, height: 20), inside: bounds)
        #expect(edge.origin == CGPoint(x: 80, y: 0))
        let huge = CaptureGeometry.kept(CGRect(x: 10, y: 10, width: 200, height: 200), inside: bounds)
        #expect(huge.origin == CGPoint(x: 0, y: -100), "a frame too big keeps its top left in view")
    }
}

struct MarkTests {
    private let red = RGB(red: 1, green: 0, blue: 0)

    @Test func dragsMakeMarks() {
        let points = [CGPoint(x: 50, y: 40), CGPoint(x: 30, y: 30), CGPoint(x: 10, y: 10)]
        let box = CGRect(x: 10, y: 10, width: 40, height: 30)
        #expect(Mark.dragged(.rectangle, along: points, color: red, width: 4)?.shape == .rectangle(box))
        #expect(Mark.dragged(.ellipse, along: points, color: red, width: 4)?.shape == .ellipse(box))
        #expect(Mark.dragged(.pixelate, along: points, color: red, width: 4)?.shape == .pixelate(box))
        let arrow = Mark.Shape.arrow(from: points[0], to: points[2])
        #expect(Mark.dragged(.arrow, along: points, color: red, width: 4)?.shape == arrow)
        #expect(Mark.dragged(.pen, along: points, color: red, width: 4)?.shape == .pen(points))
    }

    @Test func tinyDragsMakeNothing() {
        let tiny = [CGPoint(x: 10, y: 10), CGPoint(x: 11, y: 12)]
        for tool in [MarkTool.rectangle, .ellipse, .arrow, .pixelate] {
            #expect(Mark.dragged(tool, along: tiny, color: red, width: 4) == nil, "\(tool)")
        }
        #expect(Mark.dragged(.pen, along: [CGPoint(x: 1, y: 1)], color: red, width: 4) == nil)
        #expect(Mark.dragged(.select, along: tiny, color: red, width: 4) == nil)
    }

    /// Outlines pick on their stroke, so a click inside reaches whatever is under them.
    @Test func outlinesPickOnTheirStroke() {
        let box = CGRect(x: 100, y: 100, width: 100, height: 60)
        let rectangle = Mark(shape: .rectangle(box), color: red, width: 4)
        #expect(rectangle.contains(CGPoint(x: 100, y: 130)))
        #expect(rectangle.contains(CGPoint(x: 150, y: 165)))
        #expect(!rectangle.contains(CGPoint(x: 150, y: 130)), "the middle is see-through")
        #expect(!rectangle.contains(CGPoint(x: 300, y: 300)))
        let ellipse = Mark(shape: .ellipse(box), color: red, width: 4)
        #expect(ellipse.contains(CGPoint(x: 200, y: 130)) && ellipse.contains(CGPoint(x: 150, y: 100)))
        #expect(!ellipse.contains(CGPoint(x: 150, y: 130)) && !ellipse.contains(CGPoint(x: 102, y: 102)))
    }

    @Test func linesPickNearTheirPath() {
        let corner = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)]
        let pen = Mark(shape: .pen(corner), color: red, width: 2)
        #expect(pen.contains(CGPoint(x: 50, y: 5)) && pen.contains(CGPoint(x: 104, y: 60)))
        #expect(!pen.contains(CGPoint(x: 50, y: 50)))
        let arrow = Mark(shape: .arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 0)), color: red, width: 4)
        #expect(arrow.contains(CGPoint(x: 100, y: 3)))
        #expect(arrow.contains(CGPoint(x: 190, y: 12)), "the head is wider than the shaft")
        #expect(!arrow.contains(CGPoint(x: 100, y: 40)))
    }

    @Test func theArrowheadPointsAtTheEnd() throws {
        let head = try #require(ArrowHead(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), width: 4))
        #expect(head.tip == CGPoint(x: 100, y: 0))
        #expect(head.base == CGPoint(x: 74, y: 0), "6.5 strokes long")
        #expect(head.left == CGPoint(x: 74, y: 15) && head.right == CGPoint(x: 74, y: -15), "7.5 strokes wide")
        #expect(ArrowHead(from: .zero, to: .zero, width: 4) == nil)
    }

    /// A short arrow scales its head down, so the head never passes the tail.
    @Test func aShortArrowsHeadShrinks() throws {
        let head = try #require(ArrowHead(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: 13), width: 4))
        #expect(head.base == CGPoint(x: 0, y: 0))
        #expect(head.halfWidth == 7.5)
    }

    @Test func marksMoveWhole() {
        let delta = CGVector(dx: 5, dy: -3)
        let line = Mark(shape: .pen([CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)]), color: red, width: 2)
        let moved = line.moved(by: delta)
        #expect(moved.shape == .pen([CGPoint(x: 6, y: -2), CGPoint(x: 7, y: -1)]))
        let text = Mark(shape: .text("Hi", at: CGPoint(x: 10, y: 10)), color: red, width: 2).moved(by: delta)
        #expect(text.shape == .text("Hi", at: CGPoint(x: 15, y: 7)))
        let arrow = Mark(shape: .arrow(from: .zero, to: CGPoint(x: 10, y: 0)), color: red, width: 2).moved(by: delta)
        #expect(arrow.shape == .arrow(from: CGPoint(x: 5, y: -3), to: CGPoint(x: 15, y: -3)))
    }

    @Test func textAndNumbersGrowWithTheStroke() {
        let thin = Mark(shape: .text("Topdeck", at: .zero), color: red, width: 2).bounds
        let thick = Mark(shape: .text("Topdeck", at: .zero), color: red, width: 8).bounds
        #expect(thin.width > 0 && thick.width > thin.width * 1.5)
        let number = Mark(shape: .counter(3, at: CGPoint(x: 50, y: 50)), color: red, width: 4).bounds
        #expect(number.midX == 50 && number.midY == 50 && number.width == Mark.counterDiameter(for: 4))
    }
}

@MainActor
struct MarkupModelTests {
    private func drag(_ model: MarkupModel, from start: CGPoint, to end: CGPoint) {
        model.press(at: start)
        model.drag(to: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2))
        model.release(at: end)
    }

    @Test func drawingThenUndoAndRedo() {
        let model = MarkupModel()
        model.tool = .rectangle
        drag(model, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 40))
        #expect(model.marks.map(\.shape) == [.rectangle(CGRect(x: 10, y: 10, width: 50, height: 30))])
        #expect(model.draft == nil && model.canUndo && !model.canRedo)
        model.undo()
        #expect(model.marks.isEmpty && model.canRedo)
        model.redo()
        #expect(model.marks.count == 1)
    }

    @Test func theDraftShowsWhileDragging() {
        let model = MarkupModel()
        model.tool = .arrow
        model.press(at: CGPoint(x: 0, y: 0))
        model.drag(to: CGPoint(x: 50, y: 50))
        #expect(model.draft?.shape == .arrow(from: .zero, to: CGPoint(x: 50, y: 50)))
        #expect(model.marks.isEmpty)
    }

    @Test func selectMovesAMarkAndOneUndoPutsItBack() {
        let model = MarkupModel()
        model.tool = .rectangle
        drag(model, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 40))
        model.tool = .select
        model.press(at: CGPoint(x: 10, y: 25))
        #expect(model.selection == 0)
        model.drag(to: CGPoint(x: 20, y: 30))
        model.drag(to: CGPoint(x: 30, y: 35))
        model.release(at: CGPoint(x: 30, y: 35))
        #expect(model.marks.first?.shape == .rectangle(CGRect(x: 30, y: 20, width: 50, height: 30)))
        model.undo()
        #expect(model.marks.first?.shape == .rectangle(CGRect(x: 10, y: 10, width: 50, height: 30)))
    }

    @Test func aColourPickedWithAMarkSelectedRecolorsIt() {
        let model = MarkupModel()
        model.tool = .rectangle
        drag(model, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 40))
        model.tool = .select
        model.press(at: CGPoint(x: 10, y: 25))
        model.release(at: CGPoint(x: 10, y: 25))
        model.color = RGB.markColors[3]
        #expect(model.marks.first?.color == RGB.markColors[3])
        model.deleteSelection()
        #expect(model.marks.isEmpty)
        model.undo()
        #expect(model.marks.count == 1)
    }

    @Test func numbersCountUp() {
        let model = MarkupModel()
        model.tool = .counter
        model.press(at: CGPoint(x: 10, y: 10))
        model.release(at: CGPoint(x: 10, y: 10))
        model.press(at: CGPoint(x: 40, y: 10))
        model.release(at: CGPoint(x: 40, y: 10))
        let expected: [Mark.Shape] = [.counter(1, at: CGPoint(x: 10, y: 10)), .counter(2, at: CGPoint(x: 40, y: 10))]
        #expect(model.marks.map(\.shape) == expected)
    }

    @Test func emptyTextAddsNothing() {
        let model = MarkupModel()
        model.addText("  \n", at: .zero)
        #expect(model.marks.isEmpty)
        model.addText("Look here", at: CGPoint(x: 5, y: 5))
        #expect(model.marks.map(\.shape) == [.text("Look here", at: CGPoint(x: 5, y: 5))])
    }
}

struct MarkRendererTests {
    private func white(width: Int, height: Int) throws -> CGImage {
        try bgraImage((0..<height).map { _ in [UInt8](repeating: 255, count: width) })
    }

    /// The image's pixels as (red, green, blue), row by row from the top.
    private func pixels(_ image: CGImage) throws -> [[(Int, Int, Int)]] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<image.height).map { y in
            (0..<image.width).map { x in
                let start = (y * image.width + x) * 4
                return (Int(bytes[start]), Int(bytes[start + 1]), Int(bytes[start + 2]))
            }
        }
    }

    @Test func noMarksIsTheCaptureItself() throws {
        let image = try white(width: 10, height: 10)
        #expect(MarkRenderer.render(image, marks: [], scale: 2) === image)
    }

    /// Marks are in points from the top left; on a Retina capture each point is two pixels.
    @Test func marksLandWhereTheyWereDrawnAtFullResolution() throws {
        let image = try white(width: 200, height: 100)
        let red = RGB(red: 1, green: 0, blue: 0)
        let mark = Mark(shape: .rectangle(CGRect(x: 10, y: 5, width: 40, height: 20)), color: red, width: 2)
        let rendered = try #require(MarkRenderer.render(image, marks: [mark], scale: 2))
        #expect(rendered.width == 200 && rendered.height == 100)
        let rows = try pixels(rendered)
        let (r, g, b) = rows[10][40]  // the top edge: y 5 pt, x 20 pt
        #expect(r > 200 && g < 60 && b < 60)
        let (r2, g2, b2) = rows[30][60]  // inside: left alone
        #expect(r2 == 255 && g2 == 255 && b2 == 255)
        let (_, g3, _) = rows[90][40]  // below it
        #expect(g3 == 255)
    }

    @Test func pixelationHidesDetail() throws {
        // Stripes one pixel wide, which pixelation averages into a flat grey.
        let stripes = (0..<48).map { _ in (0..<48).map { UInt8($0 % 2 == 0 ? 0 : 255) } }
        let image = try bgraImage(stripes)
        let black = RGB(red: 0, green: 0, blue: 0)
        let mark = Mark(shape: .pixelate(CGRect(x: 0, y: 0, width: 24, height: 24)), color: black, width: 4)
        let rendered = try #require(MarkRenderer.render(image, marks: [mark], scale: 1))
        let rows = try pixels(rendered)
        let inside = rows[5][4].0
        #expect(abs(rows[5][5].0 - inside) <= 2, "neighbours in a block match")
        #expect((40...215).contains(inside), "stripes average out")
        #expect(abs(rows[30][30].0 - rows[30][31].0) > 200, "outside it stays sharp")
    }
}

struct RecognitionTests {
    /// Fragments on the same line in Vision's coordinates (y up), given out of order.
    @Test func fragmentsJoinIntoLinesTopToBottom() {
        let fragments = [
            TextFragment(text: "second", box: CGRect(x: 0.1, y: 0.40, width: 0.2, height: 0.05)),
            TextFragment(text: "World", box: CGRect(x: 0.32, y: 0.70, width: 0.1, height: 0.05)),
            TextFragment(text: "Hello", box: CGRect(x: 0.1, y: 0.71, width: 0.2, height: 0.05)),
            TextFragment(text: "far", box: CGRect(x: 0.8, y: 0.41, width: 0.1, height: 0.05)),
        ]
        #expect(TextRecognition.readingOrder(fragments) == ["Hello World", "second\tfar"])
        #expect(TextRecognition.readingOrder([]).isEmpty)
    }

    @Test func readsAQRCode() throws {
        let filter = try #require(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data("https://topdeck.example/capture".utf8), forKey: "inputMessage")
        let code = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        // A quiet zone around the code, as on paper.
        let margin = code.extent.insetBy(dx: -40, dy: -40).size
        let paper = CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: margin))
        let padded = code.transformed(by: CGAffineTransform(translationX: 40, y: 40)).composited(over: paper)
        let image = try #require(CIContext().createCGImage(padded, from: padded.extent))
        #expect(TextRecognition.codes(in: image) == ["https://topdeck.example/capture"])
    }

    @Test func aBlankImageHasNoCode() throws {
        let blank = try bgraImage((0..<64).map { _ in [UInt8](repeating: 255, count: 64) })
        #expect(TextRecognition.codes(in: blank).isEmpty)
    }
}

struct CaptureOutputTests {
    @Test func hexCodesRoundAndClamp() {
        #expect(ColorCode.hex(red: 0.1176, green: 0.5647, blue: 1) == "#1E90FF")
        #expect(ColorCode.hex(red: -1, green: 2, blue: 0.5) == "#00FF80")
    }

    @Test func codesTurnBackIntoColours() throws {
        let rgb = try #require(ColorCode.rgb("#1E90FF"))
        #expect(ColorCode.hex(red: rgb.red, green: rgb.green, blue: rgb.blue) == "#1E90FF")
        #expect(ColorCode.rgb("1E90FF") == nil && ColorCode.rgb("#XYZXYZ") == nil)
    }

    @Test func screenshotsAreNamedLikeMacOSNamesThem() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-30T14:03:22Z"))
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(CaptureFiles.name(at: date, timeZone: utc) == "Screenshot 2026-10-30 at 14.03.22")
    }

    @Test func savingNeverOverwrites() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "CaptureTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try CaptureFiles.save(Data([1]), named: "Shot", in: folder)
        let second = try CaptureFiles.save(Data([2]), named: "Shot", in: folder)
        #expect(first.lastPathComponent == "Shot.png" && second.lastPathComponent == "Shot 2.png")
        #expect(try Data(contentsOf: first) == Data([1]))
    }

    @Test func pngRoundTrips() throws {
        let image = try bgraImage((0..<3).map { y in (0..<5).map { UInt8($0 * 40 + y) } })
        let data = try #require(CaptureFiles.png(image))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 5 && decoded.height == 3)
    }

    @Test func aCapturesSizeInPointsFollowsItsScale() throws {
        let image = try bgraImage((0..<10).map { _ in [UInt8](repeating: 0, count: 20) })
        #expect(CaptureImage(image: image, scale: 2).pointSize == CGSize(width: 10, height: 5))
    }
}
