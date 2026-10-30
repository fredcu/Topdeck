// SPDX-License-Identifier: MIT
// Adapted from OmniMac's ScreenshotCapture (MIT), Copyright (c) 2026 Sergi (BySergiMM); see THIRD_PARTY_NOTICES.md.
import CoreGraphics
import Foundation

/// Where each frame of the area lands while the user scrolls, and which frames are kept.
///
/// It lives on its own queue (`queue`): the stream hands it about 30 frames a second and all the work
/// happens there, without slowing the app.
///
/// Each frame is compared with the one before, **also while moving**: at 30 a second, even a fast
/// scroll moves the content only a little between frames, so there's always an overlap.
///
/// All its state is touched only on `queue`, which is why it can cross threads.
final class ScrollTracker: @unchecked Sendable {
    let queue = DispatchQueue(label: "net.icuai.topdeck.scrolling-capture", qos: .userInitiated)
    /// The scroll bar's width, in pixels.
    let scrollbarPixels: Int
    /// The height covered so far, in pixels, and whether frames stopped matching (something covered
    /// the area, or it changed at once): the user should scroll back a little.
    var onProgress: (@Sendable (Int, Bool) -> Void)?

    struct Stored {
        let image: CGImage
        /// Rows from the first frame (negative after scrolling up).
        let offset: Int
        /// Taken with the content still: without the scroll bar.
        let clean: Bool
    }

    private(set) var stored: [Stored] = []
    private var topEdge: Stored?
    private var bottomEdge: Stored?
    private(set) var moves: [ScrollStitcher.Step] = []
    private(set) var signatureColumns = 0
    /// The last frame (to compare the next with) and the last one that matched.
    private var previous: (signature: ScrollStitcher.Signature, offset: Int)?
    private var lastGood: (signature: ScrollStitcher.Signature, offset: Int)?
    private var failingSince: Date?
    /// When the user last scrolled (set from the main thread, through `queue`).
    var lastScrollAt: Date?
    /// When the content last moved. The wheel isn't the only way to scroll (the keyboard, dragging
    /// the bar, a chat that writes itself): without this, all of that counted as still.
    private var lastMoveAt: Date?
    private var cleanFor: Date?
    /// Done: whatever still arrives from the stream isn't kept.
    private var isDiscarded = false
    /// The clock, replaceable in tests.
    private let now: @Sendable () -> Date

    init(scrollbarPixels: Int, now: @escaping @Sendable () -> Date = { Date() }) {
        self.scrollbarPixels = scrollbarPixels
        self.now = now
    }

    /// The last thing that moved: the wheel or the content.
    private var lastActivity: Date? {
        [lastScrollAt, lastMoveAt].compactMap { $0 }.max()
    }

    /// A second after the last movement the scroll bar is gone: those frames are the clean ones.
    private var isQuiet: Bool {
        guard let lastActivity else { return true }
        return now().timeIntervalSince(lastActivity) >= 1.0
    }

    func ingest(_ image: CGImage) {
        guard !isDiscarded else { return }
        guard let signature = ScrollStitcher.signature(of: image, ignoringTrailing: scrollbarPixels) else { return }
        signatureColumns = signature.columns
        let edge = scrollbarColumns(imageWidth: image.width)
        let clean = isQuiet
        guard let previous else {
            self.previous = (signature, 0)
            lastGood = (signature, 0)
            stored.append(Stored(image: image.copied(), offset: 0, clean: true))
            report()
            return
        }
        // The same as the last: it didn't move. Once clean, it replaces the one with the bar there.
        if ScrollStitcher.samePlace(previous.signature, signature, ignoring: edge) {
            self.previous = (signature, previous.offset)
            if clean, cleanFor != lastActivity {
                cleanFor = lastActivity
                keep(Stored(image: image.copied(), offset: previous.offset, clean: true))
                report()
            }
            return
        }
        var placed = place(signature, against: previous, edge: edge)
        if placed == nil, let lastGood { placed = place(signature, against: lastGood, edge: edge) }
        guard let offset = placed else {
            // Keeps comparing with the last good one: scrolling back recovers.
            self.previous = lastGood
            let since = failingSince ?? now()
            failingSince = since
            report(lost: now().timeIntervalSince(since) > 0.7)
            return
        }
        failingSince = nil
        self.previous = (signature, offset)
        lastGood = (signature, offset)
        lastMoveAt = now()
        // Content that moved has the scroll bar showing: never clean.
        keep(Stored(image: image, offset: offset, clean: false))
        report()
    }

    /// Where `signature` lands relative to `base`: below or above.
    private func place(
        _ signature: ScrollStitcher.Signature, against base: (signature: ScrollStitcher.Signature, offset: Int),
        edge: Int
    ) -> Int? {
        if let down = ScrollStitcher.step(from: base.signature, to: signature, edgeColumns: edge), down.shift > 0 {
            moves.append(down)
            return base.offset + down.shift
        }
        if let up = ScrollStitcher.step(from: signature, to: base.signature, edgeColumns: edge), up.shift > 0 {
            moves.append(up)
            return base.offset - up.shift
        }
        return nil
    }

    private func report(lost: Bool = false) {
        onProgress?(coveredHeight, lost)
    }

    /// The fixed header and footer: what repeats most across the steps. A real fixed bar shows the
    /// same in nearly all of them, and what varies is rows that matched by chance (too many) or a bar
    /// covered for a moment (too few). The largest left blank bands; the smallest pasted the header
    /// in as content.
    func fixedBars(height: Int) -> (top: Int, bottom: Int) {
        let cap = height / 4
        func mostCommon(_ values: [Int]) -> Int {
            let counts = Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +)
            return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key ?? 0
        }
        return (min(cap, mostCommon(moves.map(\.top))), min(cap, mostCommon(moves.map(\.bottom))))
    }

    /// The least seen: if the usual left a gap, the image is laid out with this.
    private func smallestBars(height: Int) -> (top: Int, bottom: Int) {
        let cap = height / 4
        return (min(cap, moves.map(\.top).min() ?? 0), min(cap, moves.map(\.bottom).min() ?? 0))
    }

    /// Keeps what's needed: what extends the area covered (every third of the moving part, and always
    /// the last on each side) and the clean frames. The rest, at 30 a second, would fill memory and
    /// add nothing. Kept as copies: the stream's frames are its own buffers, and holding them would
    /// leave it no room for the next.
    private func keep(_ new: Stored) {
        let copy = { Stored(image: new.image.copied(), offset: new.offset, clean: new.clean) }
        if let index = stored.firstIndex(where: { abs($0.offset - new.offset) <= 2 }) {
            if new.clean, !stored[index].clean { stored[index] = copy() }
            return
        }
        let bars = fixedBars(height: new.image.height)
        let spacing = max(1, (new.image.height - bars.top - bars.bottom) / 3)
        guard let lowest = stored.map(\.offset).min(), let highest = stored.map(\.offset).max() else {
            stored.append(copy())
            return
        }
        if new.offset > highest {
            if new.offset - highest >= spacing, let edge = bottomEdge, edge.offset > highest {
                stored.append(edge)
                bottomEdge = nil
            }
            let top = stored.map(\.offset).max() ?? highest
            if new.clean || new.offset - top >= spacing {
                stored.append(copy())
                bottomEdge = nil
            } else {
                bottomEdge = copy()
            }
        } else if new.offset < lowest {
            if lowest - new.offset >= spacing, let edge = topEdge, edge.offset < lowest {
                stored.append(edge)
                topEdge = nil
            }
            let bottom = stored.map(\.offset).min() ?? lowest
            if new.clean || bottom - new.offset >= spacing {
                stored.append(copy())
                topEdge = nil
            } else {
                topEdge = copy()
            }
        } else if new.clean {
            stored.append(copy())
        }
    }

    var coveredHeight: Int {
        let offsets = stored.map(\.offset) + [topEdge, bottomEdge].compactMap { $0?.offset }
        guard let lowest = offsets.min(), let highest = offsets.max(), let height = stored.first?.image.height else {
            return 0
        }
        return highest - lowest + height
    }

    /// The scroll bar, in signature columns.
    func scrollbarColumns(imageWidth: Int) -> Int {
        let measured = imageWidth - scrollbarPixels
        guard measured > 0, signatureColumns > 0 else { return 0 }
        return Int((Double(scrollbarPixels * signatureColumns) / Double(measured)).rounded(.up))
    }

    /// Lets go of the kept frames. They're tens of MB, and anything holding on to the tracker
    /// (ScreenCaptureKit keeps the stream's output after it stops) would pile them up capture after
    /// capture.
    func discard() {
        stored.removeAll()
        topEdge = nil
        bottomEdge = nil
        isDiscarded = true
    }

    /// The final image: everything kept, laid out in layers.
    func compose() -> CGImage? {
        let edges = [topEdge, bottomEdge].compactMap { $0 }
        for edge in edges where !stored.contains(where: { $0.offset == edge.offset }) { stored.append(edge) }
        topEdge = nil
        bottomEdge = nil
        guard let first = stored.first else { return nil }
        let width = first.image.width
        let height = first.image.height
        let offsets = stored.map(\.offset)
        let clean = stored.map(\.clean)
        func plan(_ bars: (top: Int, bottom: Int)) -> (height: Int, draws: [ScrollStitcher.Draw]) {
            ScrollStitcher.layout(offsets: offsets, clean: clean, height: height, top: bars.top, bottom: bars.bottom)
        }
        var layout = plan(fixedBars(height: height))
        if !ScrollStitcher.coversEverything(layout) { layout = plan(smallestBars(height: height)) }
        var columns = ScrollStitcher.keptColumns(moves).map { pixelRange($0, imageWidth: width) } ?? 0..<width
        // Frames taken while moving carry the scroll bar at the right edge of what moves. If any is
        // in the image, that strip goes: otherwise a piece of the bar would show in every strip.
        if stored.contains(where: { !$0.clean }) {
            let trim = min(scrollbarPixels, columns.count / 10)
            columns = columns.lowerBound..<(columns.upperBound - trim)
        }
        return ScrollStitcher.render(images: stored.map(\.image), plan: layout, xRange: columns)
    }

    /// From signature columns to pixels. The signature leaves out the right edge (the bar): a crop
    /// that reaches the end reaches the real edge.
    private func pixelRange(_ kept: Range<Int>, imageWidth: Int) -> Range<Int> {
        let measured = imageWidth - scrollbarPixels
        let count = signatureColumns
        guard count > 0, measured > 0 else { return 0..<imageWidth }
        let lower = kept.lowerBound * measured / count
        let upper = kept.upperBound >= count ? imageWidth : (kept.upperBound * measured + count - 1) / count
        return max(0, lower)..<min(imageWidth, max(lower + 1, upper))
    }
}
