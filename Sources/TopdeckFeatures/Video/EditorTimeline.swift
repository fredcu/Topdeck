// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

/// Under the picture: the tools, the position, and the strip of frames with its trim handles, playhead and the
/// zoom (and speed) segments to drag.
struct EditorTimeline: View {
    @Bindable var model: EditorModel
    @Environment(\.deckAccent) private var accent

    private static let stripHeight: CGFloat = 50
    private static let handleWidth: CGFloat = 10

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                HStack(spacing: 5) {
                    ForEach(EditorModel.Tool.allCases) { tool in
                        Button(tool.title) { model.tool = tool }
                            .buttonStyle(.deckPill(on: model.tool == tool))
                            .frame(height: 28)
                            .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
                    }
                }
                Spacer(minLength: 12)
                Text("\(TimeText.clock(model.playhead)) / \(TimeText.clock(model.duration))")
                    .deckText(.figure, color: Deck.secondary)
                    .accessibilityLabel(
                        "Position \(TimeText.clock(model.playhead)) of \(TimeText.clock(model.duration))")
            }
            GeometryReader { space in
                let scale = TimelineScale(duration: model.duration, width: space.size.width)
                VStack(spacing: 7) {
                    strip(scale)
                    SegmentRow(model: model, kind: .zoom, scale: scale)
                    if model.tool == .speed || !model.edit.speeds.isEmpty {
                        SegmentRow(model: model, kind: .speed, scale: scale)
                    }
                }
            }
            .frame(height: Self.stripHeight + 7 + 12 + (model.tool == .speed || !model.edit.speeds.isEmpty ? 19 : 0))
        }
    }

    // MARK: The strip

    private func strip(_ scale: TimelineScale) -> some View {
        let trim = model.trim
        let (left, right) = (scale.x(trim.lowerBound), scale.x(trim.upperBound))
        return ZStack(alignment: .leading) {
            tiles(scale)
                .frame(height: Self.stripHeight)
                .clipShape(RoundedRectangle(cornerRadius: Deck.Radius.control, style: .continuous))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { model.seek(to: scale.time($0.location.x)) }
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Timeline")
                .accessibilityValue(TimeText.clock(model.playhead))
                .accessibilityAdjustableAction { direction in
                    model.seek(to: model.playhead + (direction == .increment ? 1 : -1))
                }
            // What the trim leaves out, dimmed.
            Rectangle().fill(Deck.body.opacity(0.72)).frame(width: left, height: Self.stripHeight)
                .clipShape(RoundedRectangle(cornerRadius: Deck.Radius.control, style: .continuous)).allowsHitTesting(
                    false)
            Rectangle().fill(Deck.body.opacity(0.72)).frame(
                width: max(scale.width - right, 0), height: Self.stripHeight
            )
            .offset(x: right)
            .clipShape(RoundedRectangle(cornerRadius: Deck.Radius.control, style: .continuous)).allowsHitTesting(false)
            // The kept part, outlined, with a handle at each end.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Deck.Tint.yellow, lineWidth: 2)
                .frame(width: max(right - left, 4), height: Self.stripHeight)
                .offset(x: left)
                .allowsHitTesting(false)
            handle(.start, at: left, scale: scale)
            handle(.end, at: right - Self.handleWidth, scale: scale)
            // The playhead.
            Rectangle().fill(Deck.text).frame(width: 2, height: Self.stripHeight + 4)
                .offset(x: scale.x(model.playhead) - 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(height: Self.stripHeight)
        .coordinateSpace(.named("strip"))
    }

    private func tiles(_ scale: TimelineScale) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, image in
                Color(Deck.cardRaised)
                    .overlay {
                        if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
                    }
                    .clipped()
            }
        }
        .background(Deck.cardRaised)
    }

    private func handle(_ edge: SegmentDrag.Edge, at x: CGFloat, scale: TimelineScale) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Deck.Tint.yellow)
            .frame(width: Self.handleWidth, height: Self.stripHeight)
            .overlay(Capsule().fill(Deck.onFill.opacity(0.55)).frame(width: 2, height: 16))
            .contentShape(Rectangle())
            .offset(x: x)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { value in
                    model.setTrim(edge, to: scale.time(value.location.x))
                }
            )
            .accessibilityLabel(edge == .start ? "Trim start" : "Trim end")
            .accessibilityValue(TimeText.clock(edge == .start ? model.trim.lowerBound : model.trim.upperBound))
            .accessibilityAdjustableAction { direction in
                let step: TimeInterval = direction == .increment ? 1 : -1
                model.setTrim(edge, to: (edge == .start ? model.trim.lowerBound : model.trim.upperBound) + step)
            }
    }
}

/// One row of segments under the strip, 12 points high: a block for each, to select, move and stretch.
private struct SegmentRow: View {
    enum Kind { case zoom, speed }

    @Bindable var model: EditorModel
    let kind: Kind
    let scale: TimelineScale
    @Environment(\.deckAccent) private var accent
    @State private var drag: (mode: Mode, origin: ClosedRange<TimeInterval>)?

    enum Mode { case move, start, end }

    private struct Item: Identifiable {
        let id: UUID
        let range: ClosedRange<TimeInterval>
        let selection: EditorModel.Selection
    }

    private var items: [Item] {
        switch kind {
        case .zoom: model.edit.zooms.map { Item(id: $0.id, range: $0.start...$0.end, selection: .zoom($0.id)) }
        case .speed: model.edit.speeds.map { Item(id: $0.id, range: $0.start...$0.end, selection: .speed($0.id)) }
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
            ForEach(items) { item in block(item) }
        }
        .frame(height: 12)
        .coordinateSpace(.named("row"))
    }

    private func block(_ item: Item) -> some View {
        let (left, right) = (scale.x(item.range.lowerBound), scale.x(item.range.upperBound))
        let selected = model.selection == item.selection
        let tint = kind == .zoom ? accent : Deck.Tint.yellow
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(tint.opacity(selected ? 0.9 : 0.55))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Deck.text, lineWidth: 1.5)
                }
            }
            .frame(width: max(right - left, 6), height: 12)
            .contentShape(Rectangle())
            .offset(x: left)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("row"))
                    .onChanged { value in change(item, value, left: left, right: right) }
                    .onEnded { _ in drag = nil }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(kind == .zoom ? "Zoom" : "Speed")
            .accessibilityValue(
                "from \(TimeText.clock(item.range.lowerBound)) to \(TimeText.clock(item.range.upperBound))"
            )
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.selection = item.selection }
    }

    /// The first change of a drag decides what it is by where it began: near an end it stretches, elsewhere it moves.
    private func change(_ item: Item, _ value: DragGesture.Value, left: CGFloat, right: CGFloat) {
        if drag == nil {
            let edge: CGFloat = min(7, (right - left) / 3)
            let mode: Mode =
                value.startLocation.x < left + edge ? .start : value.startLocation.x > right - edge ? .end : .move
            drag = (mode, item.range)
            model.selection = item.selection
            model.tool = kind == .zoom ? .zoom : .speed
        }
        guard let drag else { return }
        let shift = TimeInterval(value.translation.width) * scale.secondsPerPoint
        switch drag.mode {
        case .move: model.moveSegment(item.selection, to: drag.origin.lowerBound + shift)
        case .start: model.resizeSegment(item.selection, edge: .start, to: drag.origin.lowerBound + shift)
        case .end: model.resizeSegment(item.selection, edge: .end, to: drag.origin.upperBound + shift)
        }
    }
}
