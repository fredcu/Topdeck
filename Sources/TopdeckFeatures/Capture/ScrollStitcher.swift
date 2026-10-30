// SPDX-License-Identifier: MIT
// Adapted from OmniMac's ScrollStitcher (MIT), Copyright (c) 2026 Sergi (BySergiMM); see THIRD_PARTY_NOTICES.md.
import CoreGraphics
import Darwin

/// Stitches the frames of a scrolling capture: how far the content moved between two frames, and
/// which rows are new.
///
/// Rows aren't compared pixel by pixel (an 800-point area on Retina is 1,600 rows of 3,000 pixels):
/// each row shrinks to at most 1,024 luminance samples, its signature. With fewer, the digits in a
/// text blur together, "Line 147" and "Line 153" sign alike, and text, which repeats line after
/// line, lands one or more lines off.
///
/// The hard part is what doesn't move: a web page's bar, a table's header, a toolbar at the bottom.
/// Stitched as they are, they would repeat in every strip. They show up as identical rows in the same
/// place in two frames, and are left out of the search and of what's added.
enum ScrollStitcher {
    /// Per row, `columns` luminance samples (0–255), rows from the top down.
    struct Signature: Equatable {
        let columns: Int
        let rows: Int
        let values: [UInt8]

        func row(_ index: Int) -> ArraySlice<UInt8> {
            values[(index * columns)..<((index + 1) * columns)]
        }

        /// The same signature with only these columns.
        func keeping(_ kept: [Int]) -> Signature {
            var result = [UInt8]()
            result.reserveCapacity(kept.count * rows)
            for row in 0..<rows {
                let base = row * columns
                for column in kept { result.append(values[base + column]) }
            }
            return Signature(columns: kept.count, rows: rows, values: result)
        }
    }

    /// What moved from one frame to the next.
    struct Step: Equatable {
        /// Rows the content moved up. 0 means it didn't move (the end of the page).
        let shift: Int
        /// Rows at the top and bottom that don't move: fixed headers and footers.
        let top: Int
        let bottom: Int
        /// The signature columns the final image keeps, when the area held a still panel against
        /// one edge (see `step`). Nil keeps the whole width.
        var columns: Range<Int>? = nil
    }

    /// Two samples differ when they're further apart than this (out of 255).
    static let sampleThreshold = 24
    /// Columns that may differ while two rows still count as the same row. Screen captures are
    /// exact; the margin is for a blinking text cursor.
    static let rowTolerance = 1
    /// Average differing columns per row in a band that matches.
    static let tolerance = 0.5

    /// `ignoringTrailing`: pixels on the right that don't count. macOS's overlay scroll bar shows
    /// there while scrolling and fades a moment later: in one frame and not the other, no row
    /// would match.
    static func signature(of image: CGImage, columns maximum: Int = 1024, ignoringTrailing: Int = 0) -> Signature? {
        var image = image
        if ignoringTrailing > 0, ignoringTrailing < image.width / 2 {
            let kept = CGRect(x: 0, y: 0, width: image.width - ignoringTrailing, height: image.height)
            image = image.cropping(to: kept) ?? image
        }
        let rows = image.height
        let columns = min(maximum, image.width)
        guard rows > 0, columns > 0 else { return nil }
        var values = [UInt8](repeating: 0, count: rows * columns)
        let drawn = values.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            // Shrinks across only: each row stays a row.
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        return drawn ? Signature(columns: columns, rows: rows, values: values) : nil
    }

    /// Whether two frames show the same place. A few columns per row may change: the scroll bar's,
    /// which shows while moving and goes when it stops. Otherwise the clean frame taken after
    /// stopping wouldn't count as the same place.
    static func samePlace(_ a: Signature, _ b: Signature, ignoring edgeColumns: Int) -> Bool {
        guard a.rows == b.rows, a.columns == b.columns else { return false }
        let allowed = max(rowTolerance, edgeColumns + 2)
        for row in 0..<a.rows where difference(a.row(row), b.row(row)) > allowed { return false }
        return true
    }

    /// How many columns really change between two rows. A count, not an average: a different
    /// digit is a few very different columns, which an average dilutes.
    static func difference(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Int {
        var count = 0
        for (x, y) in zip(a, b) where abs(Int(x) - Int(y)) > sampleThreshold { count += 1 }
        return count
    }

    /// Average differing columns per row across `count` consecutive rows of each signature. Stops as
    /// soon as it passes the limit: most positions don't match.
    static func bandDifference(
        _ a: Signature, from aStart: Int, _ b: Signature, from bStart: Int, count: Int, limit: Double = .infinity
    ) -> Double {
        var total = 0
        let cap = limit.isFinite ? Int(limit * Double(count)) : Int.max
        for i in 0..<count {
            total += difference(a.row(aStart + i), b.row(bStart + i))
            if total > cap { return Double(total) / Double(max(1, count)) }
        }
        return Double(total) / Double(max(1, count))
    }

    /// How far the content moved from `previous` to `next`.
    ///
    /// - `expected`: the rows the scroll asked for. With repeating content (a list of identical
    ///   rows) several overlaps fit, and the nearest wins.
    /// - Returns nil when there's no reliable way to stitch them (something other than the scroll
    ///   changed, or it moved further than the area shows): better to stop than to invent.
    ///
    /// Still panels: in an app with several columns (Mail, Slack, Settings) the chosen area easily
    /// takes in a neighbouring panel. Its columns match in place in both frames; they're left out of
    /// the search (otherwise no row matches and the capture stopped at the first frame) and, when
    /// they're a panel with content against an edge, out of the final image, so it doesn't repeat in
    /// every strip. Plain margins stay.
    ///
    /// - `edgeColumns`: columns at the right edge of what moves that don't count. That's where that
    ///   area's scroll bar is, and in one frame and not the other, no row would match.
    static func step(
        from previous: Signature, to next: Signature, expected: Int? = nil, edgeColumns: Int = 0
    ) -> Step? {
        guard previous.rows == next.rows, previous.columns == next.columns, previous.rows > 8 else { return nil }
        let still = (0..<previous.columns).map { column in
            (0..<previous.rows).allSatisfy { row in
                let before = Int(previous.values[row * previous.columns + column])
                return abs(before - Int(next.values[row * next.columns + column])) <= sampleThreshold
            }
        }
        let moving = still.indices.filter { !still[$0] }
        // Only worth it when some columns are still and enough of them move.
        guard !moving.isEmpty, moving.count < previous.columns, moving.count >= 8 else {
            return movingStep(from: previous, to: next, expected: expected)
        }
        let right = moving.last ?? 0
        let matched = moving.filter { $0 < right - edgeColumns }
        let used = matched.count >= 8 ? matched : moving
        let kept = (previous.keeping(used), next.keeping(used))
        guard let step = movingStep(from: kept.0, to: kept.1, expected: expected) else { return nil }
        // Still isn't enough to be a panel: the repeated end of each line of text, or the rules
        // between a table's rows, look the same still as shifted by exactly a whole number of rows.
        // A real panel, compared shifted, doesn't match. Only the rows that move: the fixed header
        // and footer don't match shifted.
        let overlap = previous.rows - step.top - step.bottom - step.shift
        let panel = still.indices.map { column -> Bool in
            guard still[column], step.shift > 0, overlap > 0 else { return false }
            var mismatched = 0
            for row in step.top..<(step.top + overlap) {
                let before = Int(previous.values[(row + step.shift) * previous.columns + column])
                if abs(before - Int(next.values[row * next.columns + column])) > sampleThreshold { mismatched += 1 }
            }
            return mismatched > max(2, overlap / 50)
        }
        let crop = panelCrop(still: still, panel: panel, in: previous)
        return Step(shift: step.shift, top: step.top, bottom: step.bottom, columns: crop)
    }

    /// The columns the image keeps: still panels with content against an edge go (plain margins,
    /// still or not, stay).
    ///
    /// Crops up to the last panel column in each edge's still run: whatever sits between the panel
    /// and the content (a margin, a rule) goes with it.
    static func panelCrop(still: [Bool], panel: [Bool], in signature: Signature) -> Range<Int>? {
        func hasContent(_ column: Int) -> Bool {
            var low = 255
            var high = 0
            for row in 0..<signature.rows {
                let value = Int(signature.values[row * signature.columns + column])
                low = min(low, value)
                high = max(high, value)
            }
            return high - low > 24
        }
        let count = still.count
        let leading = still.prefix { $0 }.count
        let trailing = still.reversed().prefix { $0 }.count
        let isPanel = { (column: Int) in panel[column] && hasContent(column) }
        let lower = (0..<leading).last(where: isPanel).map { $0 + 1 } ?? 0
        let upper = ((count - trailing)..<count).first(where: isPanel) ?? count
        guard lower > 0 || upper < count, lower < upper else { return nil }
        return lower..<upper
    }

    /// The shift when every column looked at moves together.
    private static func movingStep(from previous: Signature, to next: Signature, expected: Int?) -> Step? {
        let height = previous.rows
        let same = (0..<height).map { difference(previous.row($0), next.row($0)) <= rowTolerance }
        if !same.contains(false) { return Step(shift: 0, top: 0, bottom: 0) }

        // Fixed parts take at most 40% at the top and as much at the bottom: more than that isn't a
        // header, it's blank content that happens to match.
        let limit = height * 2 / 5
        let top = min(limit, same.prefix { $0 }.count)
        let bottom = min(limit, same.reversed().prefix { $0 }.count)
        let bodyEnd = height - bottom
        let body = bodyEnd - top
        guard body > 8 else { return nil }

        // A band of the new frame with something in it (a blank band fits anywhere), looked for in
        // the previous one.
        let band = max(4, min(32, body / 4))
        guard let probe = probeStart(in: next, from: top, to: bodyEnd - band, band: band) else { return nil }

        var best: (shift: Int, score: Double)?
        var candidates: [(shift: Int, score: Double)] = []
        for position in top...(bodyEnd - band) {
            let shift = position - probe
            guard shift > 0 else { continue }
            let score = bandDifference(previous, from: position, next, from: probe, count: band, limit: tolerance)
            guard score <= tolerance else { continue }
            candidates.append((shift, score))
            if best == nil || score < best?.score ?? .infinity { best = (shift, score) }
        }
        guard let best else { return nil }
        // Ties (repeating content): the shift nearest the one asked for.
        let near = candidates.filter { $0.score <= best.score + 0.1 }
        let nearest = expected.flatMap { wanted in near.min { abs($0.shift - wanted) < abs($1.shift - wanted) } }
        let shift = (nearest ?? best).shift

        // Check: the whole overlap has to match, not just the band.
        let overlap = body - shift
        guard overlap > 0,
            bandDifference(previous, from: top + shift, next, from: top, count: overlap, limit: tolerance) <= tolerance
        else { return nil }
        return Step(shift: shift, top: top, bottom: bottom)
    }

    /// The first band with enough contrast for its position to be unambiguous.
    private static func probeStart(in signature: Signature, from start: Int, to end: Int, band: Int) -> Int? {
        guard end >= start else { return nil }
        var row = start
        while row <= end {
            let slice = signature.values[(row * signature.columns)..<((row + band) * signature.columns)]
            if let low = slice.min(), let high = slice.max(), Int(high) - Int(low) > 24 { return row }
            row += max(1, band / 2)
        }
        return nil
    }

    // MARK: - Layout by position (the user scrolls)

    /// A piece of a frame that goes into the final image: its rows and where they land.
    struct Draw: Equatable {
        let frame: Int
        let rows: Range<Int>
        let y: Int
    }

    /// Lays out frames whose positions are known (`offsets`, in rows from the first frame), in any
    /// order and even when areas repeat: what comes out of the user scrolling down or up at their
    /// own pace.
    ///
    /// Painted in layers: first the frames taken while moving, then on top the clean ones (`clean`),
    /// taken with the content still, without the scroll bar. The fixed header shows once at the top
    /// (from the highest frame) and the footer once at the bottom (from the lowest).
    static func layout(
        offsets: [Int], clean: [Bool], height: Int, top: Int, bottom: Int
    ) -> (height: Int, draws: [Draw]) {
        guard let lowest = offsets.min(), let highest = offsets.max(),
            let first = offsets.firstIndex(of: lowest), let last = offsets.lastIndex(of: highest)
        else { return (0, []) }
        let body = height - top - bottom
        guard body > 0 else { return (0, []) }
        let canvas = top + (highest - lowest) + body + bottom
        var draws: [Draw] = []
        if top > 0 { draws.append(Draw(frame: first, rows: 0..<top, y: 0)) }
        let order = offsets.indices.sorted { a, b in
            if clean[a] != clean[b] { return !clean[a] }  // clean frames on top
            return offsets[a] < offsets[b]
        }
        for index in order {
            draws.append(Draw(frame: index, rows: top..<(height - bottom), y: top + offsets[index] - lowest))
        }
        if bottom > 0 { draws.append(Draw(frame: last, rows: (height - bottom)..<height, y: canvas - bottom)) }
        return (canvas, draws)
    }

    // MARK: - Assembly

    /// Which rows of each frame make the final image, from the top down.
    struct Piece: Equatable {
        let frame: Int
        let rows: Range<Int>
    }

    /// The final image's columns: whatever some step keeps. A column is a panel only if it was one
    /// in every step; if a step cropped nothing, nothing is cropped.
    static func keptColumns(_ steps: [Step]) -> Range<Int>? {
        let moving = steps.filter { $0.shift > 0 }
        guard !moving.isEmpty else { return nil }
        var lower = Int.max
        var upper = Int.min
        for step in moving {
            guard let kept = step.columns else { return nil }
            lower = min(lower, kept.lowerBound)
            upper = max(upper, kept.upperBound)
        }
        return lower..<upper
    }

    /// From the first frame, everything but its fixed footer; from each following one, only the new
    /// rows (those that come in above the footer); and at the end, the footer once.
    ///
    /// Every strip is cut with **the same** footer, the largest seen. What's detected as the footer
    /// changes from step to step (a blank content row that matches beside the bar), and cutting each
    /// strip with its own left gaps or repeated rows between strips. Overshooting is safe: whatever
    /// content is in that band comes at the end, with the last frame's footer.
    static func pieces(height: Int, steps: [Step]) -> [Piece] {
        let moving = steps.filter { $0.shift > 0 }
        guard let bottom = moving.map(\.bottom).max() else { return [Piece(frame: 0, rows: 0..<height)] }
        var result = [Piece(frame: 0, rows: 0..<(height - bottom))]
        var frame = 0
        var footer = 0
        // `steps[i]` goes from frame i to frame i + 1; frames that didn't move add nothing.
        for (index, step) in steps.enumerated() {
            let current = index + 1
            guard step.shift > 0 else { continue }
            let end = height - bottom
            result.append(Piece(frame: current, rows: (end - step.shift)..<end))
            frame = current
            footer = bottom
        }
        if footer > 0 { result.append(Piece(frame: frame, rows: (height - footer)..<height)) }
        return result
    }

    /// Whether any band of the image is left unpainted.
    static func coversEverything(_ plan: (height: Int, draws: [Draw])) -> Bool {
        let spans = plan.draws.map { $0.y..<($0.y + $0.rows.count) }.sorted { $0.lowerBound < $1.lowerBound }
        var reached = 0
        for span in spans {
            if span.lowerBound > reached { return false }
            reached = max(reached, span.upperBound)
        }
        return reached >= plan.height
    }

    /// Paints the pieces where the plan says, in layers, with the columns in `xRange`.
    static func render(images: [CGImage], plan: (height: Int, draws: [Draw]), xRange: Range<Int>) -> CGImage? {
        guard let first = images.first, plan.height > 0, !xRange.isEmpty else { return nil }
        if let copied = copyRows(images: images, plan: plan, xRange: xRange) { return copied }
        let width = xRange.count
        let space = first.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil, width: width, height: plan.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        for draw in plan.draws where images.indices.contains(draw.frame) {
            // `cropping` counts from the top; the context, from the bottom.
            let crop = CGRect(x: xRange.lowerBound, y: draw.rows.lowerBound, width: width, height: draw.rows.count)
            guard let strip = images[draw.frame].cropping(to: crop) else { continue }
            let y = plan.height - draw.y - draw.rows.count
            context.draw(strip, in: CGRect(x: 0, y: y, width: width, height: draw.rows.count))
        }
        return context.makeImage()
    }

    /// Assembles the image by copying rows as they are, without drawing.
    ///
    /// Drawing each strip with `CGContext.draw` makes Core Graphics take its own copy of each
    /// image's pixels, and the result comes out of a context with memory from the regular allocator
    /// (see `MappedImage`). The stream's frames share one format, so copying rows is enough. When they
    /// don't (some tests'), nil, and it draws.
    static func copyRows(images: [CGImage], plan: (height: Int, draws: [Draw]), xRange: Range<Int>) -> CGImage? {
        guard let first = images.first, first.bitsPerPixel == 32, first.bitsPerComponent == 8 else { return nil }
        let compatible = images.allSatisfy {
            $0.bitsPerPixel == 32 && $0.bitsPerComponent == 8 && $0.bitmapInfo == first.bitmapInfo
                && $0.width >= xRange.upperBound && xRange.lowerBound >= 0
        }
        guard compatible else { return nil }
        let width = xRange.count
        let space = first.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let info = first.bitmapInfo.rawValue
        return MappedImage.make(width: width, height: plan.height, space: space, bitmapInfo: info) { out, outRow in
            // From the top down: row 0 is the top row.
            for draw in plan.draws where images.indices.contains(draw.frame) {
                let image = images[draw.frame]
                guard let data = image.dataProvider?.data, let source = CFDataGetBytePtr(data) else { return false }
                let length = CFDataGetLength(data)
                for (index, row) in draw.rows.enumerated() {
                    let target = draw.y + index
                    let from = row * image.bytesPerRow + xRange.lowerBound * 4
                    guard row >= 0, row < image.height, target >= 0, target < plan.height,
                        from + width * 4 <= length
                    else { continue }
                    memcpy(out + target * outRow, source + from, width * 4)
                }
            }
            return true
        }
    }
}

/// Large images with memory asked of the system directly (`mmap`).
///
/// The regular allocator keeps large freed blocks (a few MB each, just what each frame of the area
/// takes) and doesn't give them back even when asked: after a few scrolling captures the app went
/// from 32 MB to more than 250 and stayed there. With `mmap`, releasing the image returns it all at
/// once.
enum MappedImage {
    /// `fill` gets the buffer (rows from the top down) and its bytes per row.
    static func make(
        width: Int, height: Int, space: CGColorSpace, bitmapInfo: UInt32,
        fill: (UnsafeMutableRawPointer, Int) -> Bool
    ) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = (width * 4 + 63) & ~63
        let size = bytesPerRow * height
        guard let buffer = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
            buffer != MAP_FAILED
        else { return nil }
        let release: CGDataProviderReleaseDataCallback = { _, data, size in
            munmap(UnsafeMutableRawPointer(mutating: data), size)
        }
        guard fill(buffer, bytesPerRow),
            let provider = CGDataProvider(dataInfo: nil, data: buffer, size: size, releaseData: release)
        else {
            munmap(buffer, size)
            return nil
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent)
    }
}

extension CGImage {
    /// A copy in memory of its own: the stream's frames are buffers it wants back.
    func copied() -> CGImage {
        let space = colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let copy = MappedImage.make(width: width, height: height, space: space, bitmapInfo: info) { buffer, rowBytes in
            guard
                let context = CGContext(
                    data: buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes,
                    space: space, bitmapInfo: info)
            else { return false }
            context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return copy ?? self
    }
}
