// SPDX-License-Identifier: MIT
// Adapted from OmniMac's ScrollStitcherTests (MIT), Copyright (c) 2026 Sergi (BySergiMM); see THIRD_PARTY_NOTICES.md.
import CoreGraphics
import Foundation
import Testing

@testable import TopdeckFeatures

/// Stitching a scrolling capture, on made-up pages where exactly what must come out is known.
struct ScrollStitcherTests {
    private let width = 96

    /// A page row unlike its neighbours: stripes that change with the row number.
    private func pageRow(_ y: Int) -> [UInt8] {
        (0..<width).map { x in UInt8(truncatingIfNeeded: (x * 7 + y * 13 + (x / 9) * y) % 251) }
    }

    private func uniformRow(_ value: UInt8) -> [UInt8] { [UInt8](repeating: value, count: width) }

    private func image(_ rows: [[UInt8]]) -> CGImage {
        grayImage(rows, width: rows.first?.count ?? width)
    }

    /// What a window `viewport` rows tall shows of the page scrolled by `offset`, with `header` fixed
    /// rows at the top and `footer` at the bottom.
    private func frame(offset: Int, viewport: Int, header: Int = 0, footer: Int = 0) -> [[UInt8]] {
        let headerRows = (0..<header).map { uniformRow($0 % 2 == 0 ? 30 : 220) }
        let body = (0..<(viewport - header - footer)).map { pageRow(offset + $0) }
        let footerRows = (0..<footer).map { uniformRow($0 % 3 == 0 ? 200 : 60) }
        return headerRows + body + footerRows
    }

    private func signature(_ rows: [[UInt8]]) throws -> ScrollStitcher.Signature {
        try #require(ScrollStitcher.signature(of: image(rows), columns: rows[0].count))
    }

    private func matchSteps(_ frames: [[[UInt8]]], expected: Int) throws -> [ScrollStitcher.Step] {
        try (1..<frames.count).map { index in
            let step = ScrollStitcher.step(
                from: try signature(frames[index - 1]), to: try signature(frames[index]), expected: expected)
            return try #require(step)
        }
    }

    /// The rows as the final assembly joins them.
    private func assemble(_ frames: [[[UInt8]]], steps: [ScrollStitcher.Step]) -> [[UInt8]] {
        ScrollStitcher.pieces(height: frames[0].count, steps: steps).flatMap { piece in
            Array(frames[piece.frame][piece.rows])
        }
    }

    @Test func findsTheShift() throws {
        let a = try signature(frame(offset: 0, viewport: 200))
        let b = try signature(frame(offset: 70, viewport: 200))
        let step = try #require(ScrollStitcher.step(from: a, to: b, expected: 70))
        #expect(step == ScrollStitcher.Step(shift: 70, top: 0, bottom: 0))
    }

    @Test func noMovementIsTheEnd() throws {
        let a = try signature(frame(offset: 300, viewport: 200))
        #expect(ScrollStitcher.step(from: a, to: a)?.shift == 0)
    }

    @Test func rebuildsThePage() throws {
        let frames = [0, 70, 140, 210, 245].map { frame(offset: $0, viewport: 200) }
        let steps = try matchSteps(frames, expected: 70)
        #expect(steps.map(\.shift) == [70, 70, 70, 35], "the last step is shorter: the end of the page")
        #expect(assemble(frames, steps: steps) == (0..<445).map(pageRow))
    }

    @Test func fixedHeaderAndFooterShowOnce() throws {
        let frames = [0, 70, 140].map { frame(offset: $0, viewport: 200, header: 20, footer: 15) }
        let steps = try matchSteps(frames, expected: 70)
        #expect(steps.map(\.shift) == [70, 70])
        #expect(steps.first?.top == 20 && steps.first?.bottom == 15)
        let body = 200 - 20 - 15
        let expected = Array(frames[0].prefix(20)) + (0..<(body + 140)).map(pageRow) + Array(frames[0].suffix(15))
        #expect(assemble(frames, steps: steps) == expected)
    }

    @Test func refusesFramesThatDontMatch() throws {
        let a = try signature(frame(offset: 0, viewport: 200))
        let other = (0..<200).map { y in (0..<width).map { x in UInt8(truncatingIfNeeded: (x * x + y * 31) % 241) } }
        #expect(ScrollStitcher.step(from: a, to: try signature(other)) == nil)
    }

    @Test func aSingleFrameIsTheFrame() {
        #expect(ScrollStitcher.pieces(height: 200, steps: []) == [.init(frame: 0, rows: 0..<200)])
        let still = ScrollStitcher.Step(shift: 0, top: 0, bottom: 0)
        #expect(ScrollStitcher.pieces(height: 200, steps: [still]) == [.init(frame: 0, rows: 0..<200)])
    }

    /// Like text: each line is 12 rows and every line is the same but for a few columns, its number.
    /// With a coarse signature the lines blurred together and the text landed lines off.
    @Test func textLinesThatDifferOnlyInTheirNumber() throws {
        let wide = 1000
        func textRow(_ y: Int) -> [UInt8] {
            let line = y / 12
            let inLine = y % 12
            var row = [UInt8](repeating: 250, count: wide)
            guard (2...9).contains(inLine) else { return row }  // the space between lines
            for x in stride(from: 120, to: 900, by: 9) { row[x] = 20 }  // the text, the same on every line
            // The number: four digits six columns wide, different on each line.
            for digit in 0..<4 {
                let value = (line / Int(pow(10.0, Double(digit)))) % 10
                for x in 0..<6 where (value + x + inLine) % 3 == 0 { row[40 + digit * 8 + x] = 10 }
            }
            return row
        }
        func page(_ offset: Int) -> CGImage { grayImage((0..<300).map { textRow(offset + $0) }, width: wide) }
        // Asked to scroll 160, the app scrolls 168 (fourteen lines): not 156, nor 168 ± 12.
        let a = try #require(ScrollStitcher.signature(of: page(0)))
        let b = try #require(ScrollStitcher.signature(of: page(168)))
        #expect(ScrollStitcher.step(from: a, to: b, expected: 160)?.shift == 168)
    }

    /// The footer detected changes from step to step. Even when one step thinks it's taller, the page
    /// comes out whole, with no repeated rows.
    @Test func aFooterThatLooksTallerSometimesLeavesNoGaps() {
        let frames = [0, 70, 140, 210].map { frame(offset: $0, viewport: 200, header: 20, footer: 15) }
        let steps: [ScrollStitcher.Step] = [
            .init(shift: 70, top: 20, bottom: 15),
            .init(shift: 70, top: 20, bottom: 24),  // nine content rows taken for footer
            .init(shift: 70, top: 26, bottom: 15),
        ]
        let body = 200 - 20 - 15
        let expected = Array(frames[0].prefix(20)) + (0..<(body + 210)).map(pageRow) + Array(frames[0].suffix(15))
        #expect(assemble(frames, steps: steps) == expected)
    }

    /// As in Mail: the area also takes in a panel beside it that doesn't move. The panel is cropped;
    /// the plain margin beside it stays.
    @Test func aStillPanelBesideTheContent() throws {
        let panelWidth = 30
        func panelRow(_ y: Int) -> [UInt8] { (0..<panelWidth).map { x in UInt8((x * 11 + y * 3) % 200 + 20) } }
        let gap = [UInt8](repeating: 250, count: 6)
        let frames = [0, 70, 140].map { offset in (0..<200).map { y in panelRow(y) + gap + pageRow(offset + y) } }
        let steps = try matchSteps(frames, expected: 70)
        #expect(steps.map(\.shift) == [70, 70])
        let kept = try #require(steps.first?.columns)
        #expect(kept == panelWidth..<(panelWidth + 6 + width))
        let rows = ScrollStitcher.pieces(height: 200, steps: steps).flatMap { piece in
            frames[piece.frame][piece.rows].map { Array($0[kept]) }
        }
        #expect(rows == (0..<340).map { gap + pageRow($0) })
    }

    @Test func noCropWithoutAPanel() throws {
        let a = try signature(frame(offset: 0, viewport: 200))
        let b = try signature(frame(offset: 70, viewport: 200))
        #expect(ScrollStitcher.step(from: a, to: b, expected: 70)?.columns == nil)
    }

    // MARK: The user scrolls

    private func compose(
        _ frames: [[[UInt8]]], offsets: [Int], clean: [Bool], top: Int = 0, bottom: Int = 0
    ) -> [[UInt8]] {
        let plan = ScrollStitcher.layout(
            offsets: offsets, clean: clean, height: frames[0].count, top: top, bottom: bottom)
        var canvas = [[UInt8]](repeating: [], count: plan.height)
        for draw in plan.draws {
            for (index, row) in draw.rows.enumerated() { canvas[draw.y + index] = frames[draw.frame][row] }
        }
        return canvas
    }

    @Test func scrollingDownUpAndDownAgain() {
        let offsets = [0, 70, 30, 140, 200]
        let frames = offsets.map { frame(offset: $0, viewport: 200) }
        let rows = compose(frames, offsets: offsets, clean: [true, false, false, false, true])
        #expect(rows == (0..<400).map(pageRow))
    }

    @Test func scrollingUpFromTheBottom() {
        let offsets = [300, 230, 160]
        let frames = offsets.map { frame(offset: $0, viewport: 200) }
        let rows = compose(frames, offsets: offsets.map { $0 - 300 }, clean: [true, false, true])
        #expect(rows == (160..<500).map(pageRow))
    }

    @Test func fixedBarsShowOnceWhileScrolling() {
        let offsets = [0, 70, 140]
        let frames = offsets.map { frame(offset: $0, viewport: 200, header: 20, footer: 15) }
        let rows = compose(frames, offsets: offsets, clean: [true, true, true], top: 20, bottom: 15)
        let expected = Array(frames[0].prefix(20)) + (0..<(165 + 140)).map(pageRow) + Array(frames[0].suffix(15))
        #expect(rows == expected)
    }

    @Test func cleanFramesGoOnTop() {
        let clean = [false, true, false]
        let plan = ScrollStitcher.layout(offsets: [0, 0, 70], clean: clean, height: 200, top: 0, bottom: 0)
        #expect(plan.draws.map(\.frame) == [0, 2, 1])
    }

    /// Once scrolling stops, the clean frame (without the scroll bar) is the same place.
    @Test func theCleanFrameIsTheSamePlace() throws {
        let page = frame(offset: 40, viewport: 200)
        var withBar = page
        for y in 60..<120 {
            for x in (width - 6)..<(width - 2) { withBar[y][x] = 90 }
        }
        #expect(ScrollStitcher.samePlace(try signature(withBar), try signature(page), ignoring: 6))
        let moved = try signature(frame(offset: 41, viewport: 200))
        #expect(!ScrollStitcher.samePlace(try signature(page), moved, ignoring: 6), "moving isn't the same place")
    }

    @Test func findsGapsInThePlan() {
        let tight = ScrollStitcher.layout(offsets: [0, 100], clean: [true, true], height: 200, top: 20, bottom: 20)
        #expect(ScrollStitcher.coversEverything(tight))
        let gap = ScrollStitcher.layout(offsets: [0, 190], clean: [true, true], height: 200, top: 40, bottom: 40)
        #expect(!ScrollStitcher.coversEverything(gap))
    }

    /// Assembly copies rows as they are, and has to give what drawing gives: each row in its place,
    /// cropped.
    @Test func copyingRowsGivesWhatDrawingGives() throws {
        func sample(_ base: UInt8) -> [[UInt8]] { (0..<10).map { y in (0..<8).map { x in base &+ UInt8(y * 8 + x) } } }
        let images = [try bgraImage(sample(0)), try bgraImage(sample(100))]
        let draws = [
            ScrollStitcher.Draw(frame: 0, rows: 0..<10, y: 0), ScrollStitcher.Draw(frame: 1, rows: 6..<10, y: 10),
        ]
        let plan = (height: 14, draws: draws)
        let copied = try #require(ScrollStitcher.copyRows(images: images, plan: plan, xRange: 2..<6))
        #expect(copied.width == 4 && copied.height == 14)
        let rows = try blueRows(of: copied)
        #expect(rows[0][0] == 2, "row 0, column 2 of the first")
        #expect(rows[9][3] == UInt8(9 * 8 + 5), "the first's last row")
        #expect(rows[10][0] == 100 + UInt8(6 * 8 + 2), "the second's row 6, below it")
        let space = CGColorSpaceCreateDeviceRGB()
        let last = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = CGContext(
            data: nil, width: 8, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: last)
        let rgba = try #require(context?.makeImage())
        #expect(ScrollStitcher.copyRows(images: [images[0], rgba], plan: plan, xRange: 2..<6) == nil, "draws instead")
    }

    /// The tracker, fed frames as the stream would, keeps what's needed and puts the page back
    /// together.
    @Test func theTrackerRebuildsAScrolledPage() throws {
        let tracker = ScrollTracker(scrollbarPixels: 0)
        let offsets = [0, 0, 70, 140, 140, 210]
        for offset in offsets { tracker.ingest(try bgraImage(frame(offset: offset, viewport: 200))) }
        #expect(tracker.coveredHeight == 410)
        let composed = try #require(tracker.compose())
        #expect(try blueRows(of: composed) == (0..<410).map(pageRow))
    }

    @Test func aDiscardedTrackerKeepsNothing() throws {
        let tracker = ScrollTracker(scrollbarPixels: 0)
        tracker.ingest(try bgraImage(frame(offset: 0, viewport: 200)))
        tracker.discard()
        tracker.ingest(try bgraImage(frame(offset: 70, viewport: 200)))
        #expect(tracker.stored.isEmpty && tracker.compose() == nil)
    }
}

/// An 8-bit grey image from rows of samples, the top row first.
func grayImage(_ rows: [[UInt8]], width: Int) -> CGImage {
    var bytes = rows.flatMap { $0 }
    return bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: width, height: rows.count, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        return context!.makeImage()!
    }
}

/// A BGRA image, as the stream delivers, whose colour channels all hold the samples: grey, top row first.
func bgraImage(_ rows: [[UInt8]]) throws -> CGImage {
    let width = rows.first?.count ?? 0
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    let context = try #require(
        CGContext(
            data: nil, width: width, height: rows.count, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info))
    let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    for (y, row) in rows.enumerated() {
        for (x, value) in row.enumerated() {
            let start = y * context.bytesPerRow + x * 4
            for channel in 0..<3 { pixels[start + channel] = value }
            pixels[start + 3] = 255
        }
    }
    return try #require(context.makeImage())
}

/// The first byte of each pixel (blue, in BGRA) of a 32-bit image, row by row from the top.
func blueRows(of image: CGImage) throws -> [[UInt8]] {
    let data = try #require(image.dataProvider?.data)
    let bytes = try #require(CFDataGetBytePtr(data))
    return (0..<image.height).map { y in (0..<image.width).map { x in bytes[y * image.bytesPerRow + x * 4] } }
}
