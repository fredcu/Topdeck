// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckCore

/// The open deck's contents: the top row with the spaces in two wings around the camera, the second
/// row with the space's title and its actions, and the body. The panel and its black shape
/// are the notch view's; the deck never changes size when the space does.
struct DeckView: View {
    let engine: NotchEngine
    let metrics: NotchMetrics
    let preferences: NotchPreferences
    let content: NotchContent
    let space: SpaceID
    let pinned: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The open size when a resize drag began, while one is under way.
    @State private var resizeStart: CGSize?

    /// What the body shows, so a change of either fades.
    private struct Page: Hashable {
        var space: SpaceID
        var detail: FeatureID?
    }

    var body: some View {
        let state = engine.state
        let detail = state.detail
        VStack(spacing: 0) {
            wings(state.spaceSet)
            secondRow(detail: detail)
                .zIndex(1)  // the add field's style panel hangs over the columns
            pageBody(Page(space: space, detail: detail), enabled: state.spaceSet.enabled)
        }
        // Inside the shoulders, which are the shape's concave top corners.
        .padding(.horizontal, metrics.notch == nil ? 0 : NotchMetrics.shoulder)
        .overlay(alignment: .bottomTrailing) {
            // Inside the bottom corner's rounding, in the margin under the cards.
            resizeGrip
                .padding(.trailing, (metrics.notch == nil ? 0 : NotchMetrics.shoulder) + 8)
                .padding(.bottom, 8)
        }
        .foregroundStyle(Deck.text)
        .environment(\.deckAccent, space.accent)
        .environment(\.deckDetail, detail)
        .environment(\.openDeckDetail, DeckDetailOpener { [engine] in engine.send(.openDetail($0)) })
    }

    // MARK: Top row

    /// Three spaces in each wing, the camera between them. The same gap on a display without a notch.
    private func wings(_ set: SpaceSet) -> some View {
        HStack(spacing: 0) {
            wing(set.wings.left).frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: metrics.housing.width)
            wing(set.wings.right).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: metrics.topRowHeight)
    }

    /// The spaces of one wing, falling back to tighter pills when the smallest deck has no room for the
    /// usual ones with a badge.
    private func wing(_ spaces: [SpaceID]) -> some View {
        ViewThatFits(in: .horizontal) {
            wingRow(spaces, compact: false)
            wingRow(spaces, compact: true)
        }
        .padding(.horizontal, 10)
    }

    private func wingRow(_ spaces: [SpaceID], compact: Bool) -> some View {
        HStack(spacing: compact ? 2 : 4) {
            ForEach(spaces) { item in
                DeckNavItem(
                    item.title, accent: item.accent, selected: item == space, badge: content.badge(item),
                    compact: compact
                ) {
                    engine.send(.selectSpace(item))
                }
            }
        }
    }

    // MARK: Second row

    private func secondRow(detail: FeatureID?) -> some View {
        HStack(alignment: space == .now ? .top : .center, spacing: 0) {
            if let detail {
                // A screen over the body: back to the page, and its name.
                HStack(spacing: 4) {
                    DeckIconButton(.chevronLeft, label: "Back") { engine.send(.openDetail(nil)) }
                    Text(space.detailTitle(detail)).deckText(.title).lineLimit(1)
                }
                .padding(.leading, -6)
            } else if space == .now {
                DeckClock()
            } else if let leading = content.leading(space) {
                leading
            } else {
                Text(space.headline()).deckText(.title).lineLimit(1)
            }
            if space == .now {
                // The one slot between the clock and the actions: a request, a meeting, the add field.
                // Clear behind it, so the slot keeps its width, and the actions their place, when it is empty.
                ZStack(alignment: .leading) {
                    Color.clear.frame(height: 1)
                    content.slot(space)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)
                .padding(.trailing, 12)
            } else {
                Spacer(minLength: Deck.Metric.gap)
            }
            HStack(spacing: 2) {
                content.actions(space, detail)
                DeckIconButton(.pin, label: pinned ? "Unpin" : "Keep open", on: pinned) { engine.send(.togglePin) }
                DeckIconButton(.gear, label: "Settings") { content.openSettings() }
            }
            .padding(.top, space == .now ? 1 : 0)
        }
        .padding(.horizontal, Deck.Metric.inset)
        .padding(.top, space == .now ? 2 : 0)
        .frame(height: space == .now ? Deck.Metric.nowRow : Deck.Metric.subRow, alignment: .top)
    }

    // MARK: Body

    private func pageBody(_ page: Page, enabled: Set<FeatureID>) -> some View {
        ZStack {
            pageContent(page, enabled: enabled)
                .id(page)
                .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: page)
        .padding(.horizontal, space == .now ? Deck.Metric.inset : Deck.Metric.side)
        .padding(.bottom, Deck.Metric.side)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Overlay scroll bars would sit on top of lists; faded edges show there's more.
        .scrollIndicators(.never)
    }

    /// Now draws its own columns, and so do the spaces with a screen of their own. The rest lay the
    /// views of the features that are on side by side.
    @ViewBuilder private func pageContent(_ page: Page, enabled: Set<FeatureID>) -> some View {
        if space == .now {
            content.now()
        } else if let screen = content.screen(space, enabled) {
            screen
        } else {
            HStack(alignment: .top, spacing: Deck.Metric.gap) {
                ForEach(space.features.filter(enabled.contains), id: \.self) { feature in
                    content.feature(feature).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    // MARK: Resizing

    /// The size a corner drag asks for, in whole points: the deck grows to both sides of its center
    /// and down from the screen's edge, so the width moves twice as far as the pointer.
    static func resized(_ start: CGSize, by drag: CGSize) -> CGSize {
        CGSize(width: (start.width + 2 * drag.width).rounded(), height: (start.height + drag.height).rounded())
    }

    /// Drag the corner to resize, anywhere between the smallest and largest size. The deck grows from
    /// its center, so width moves twice as far as the pointer and the corner stays under it. Holding the
    /// button keeps the deck open even past its edge. VoiceOver steps through sizes instead.
    private var resizeGrip: some View {
        ResizeGrip(active: resizeStart != nil)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .gesture(
                // Global: the grip moves with the corner, so a local translation would chase itself.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = resizeStart ?? preferences.expandedSize
                        resizeStart = start
                        preferences.resizeExpanded(to: Self.resized(start, by: drag.translation))
                    }
                    .onEnded { _ in resizeStart = nil }
            )
            .resizeCursor()
            .help("Drag to resize")
            .accessibilityElement()
            .accessibilityLabel("Resize")
            .accessibilityValue("\(Int(preferences.expandedSize.width)) by \(Int(preferences.expandedSize.height))")
            .accessibilityAdjustableAction { direction in
                guard let next = preferences.expandedSizeStep(larger: direction == .increment) else { return }
                withAnimation(reduceMotion ? .easeInOut(duration: 0.12) : .snappy(duration: 0.2)) {
                    preferences.resizeExpanded(to: next)
                }
            }
    }
}

extension SpaceID {
    /// The title at the left of the second row.
    func headline() -> String { title }
}

/// Three diagonal strokes that run from the right edge to the bottom edge, like a window's resize
/// corner. They brighten under the pointer and while dragging.
private struct ResizeGrip: View {
    let active: Bool
    @State private var hovering = false

    var body: some View {
        Canvas { context, size in
            var strokes = Path()
            for inset in [4.0, 8.0, 12.0] {
                strokes.move(to: CGPoint(x: size.width, y: size.height - inset))
                strokes.addLine(to: CGPoint(x: size.width - inset, y: size.height))
            }
            context.stroke(strokes, with: .color(Deck.text), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .opacity(active ? 0.95 : hovering ? 0.75 : 0.5)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityHidden(true)
    }
}

extension View {
    /// The diagonal resize cursor, where macOS has one (15 and later).
    @ViewBuilder fileprivate func resizeCursor() -> some View {
        if #available(macOS 15, *) {
            pointerStyle(.frameResize(position: .bottomTrailing))
        } else {
            self
        }
    }
}
