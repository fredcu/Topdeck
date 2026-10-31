// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

extension CaptureFeature.Tool {
    var icon: DeckIcon {
        switch self {
        case .screenshot: .area
        case .window: .window
        case .screen: .display
        case .scrolling: .scrollingCapture
        case .text: .recognizeText
        case .qrCode: .qrCode
        case .color: .colorPicker
        case .pin: .pin
        }
    }

    /// The tile's label, as the Tools board words it.
    var tileTitle: String { self == .screenshot ? "Area" : title }

    /// The tiles of the first row, in the board's order.
    static let tiles: [CaptureFeature.Tool] = [.screenshot, .window, .screen, .scrolling, .text]
}

/// A square tool tile on the Tools screen: an icon chip over a name. `tint` colours the chip; a tile whose
/// tool isn't built yet is dimmed, and its `.help` says so.
struct ToolTile: View {
    let title: String
    let icon: DeckIcon
    let tint: Color
    var compact = false
    var disabledHelp: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: compact ? 4 : 6) {
                DeckIconView(icon, size: compact ? 14 : 16)
                    .foregroundStyle(tint)
                    .frame(width: compact ? 24 : 28, height: compact ? 24 : 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.tint(0.2)))
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(Deck.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: Deck.Radius.tile, style: .continuous).fill(Deck.card))
            .overlay(
                RoundedRectangle(cornerRadius: Deck.Radius.tile, style: .continuous)
                    .strokeBorder(Deck.hairline, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Deck.Radius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabledHelp != nil)
        .opacity(disabledHelp == nil ? 1 : 0.45)
        .help(disabledHelp ?? "")
        .accessibilityLabel(title)
    }
}

/// The capture tools as two rows of tiles, and the captures kept lately under them.
struct CaptureView: View {
    let capture: CaptureFeature
    var compact = false

    var body: some View {
        VStack(spacing: 9) {
            row(CaptureFeature.Tool.tiles.count) {
                ForEach(CaptureFeature.Tool.tiles) { tool in
                    ToolTile(title: tool.tileTitle, icon: tool.icon, tint: accent, compact: compact) {
                        capture.run(tool)
                    }
                }
            }
            // Recording and the video editor are built in a later batch.
            row(3) {
                ToolTile(
                    title: "Record Window", icon: .window, tint: Deck.Tint.record, compact: compact,
                    disabledHelp: Self.soon
                ) {}
                ToolTile(
                    title: "Record Screen", icon: .display, tint: Deck.Tint.record, compact: compact,
                    disabledHelp: Self.soon
                ) {}
                ToolTile(
                    title: "Edit Video", icon: .film, tint: Deck.Accent.clipboard, compact: compact,
                    disabledHelp: Self.soon
                ) {}
            }
            RecentCaptures(capture: capture, compact: compact)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    static let soon = "Coming next"
    @Environment(\.deckAccent) private var accent

    private func row<Content: View>(_ count: Int, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }.frame(height: compact ? 56 : 80)
    }
}

/// Thumbnails of the newest captures: as many as fit, each with its kind and time. Click opens one, drag
/// takes the file out, and the context menu copies, reveals or deletes it.
struct RecentCaptures: View {
    let capture: CaptureFeature
    var compact = false

    /// The narrowest a thumbnail goes before another one is left out.
    private var minimumWidth: CGFloat { compact ? 84 : 96 }
    private var thumbHeight: CGFloat { compact ? 52 : 74 }

    var body: some View {
        GeometryReader { space in
            let fit = Int((space.size.width + 8) / (minimumWidth + 8))
            let shown = Array(capture.recents.prefix(max(fit, 1)))
            HStack(alignment: .top, spacing: 8) {
                ForEach(shown) { item in
                    RecentThumbnail(capture: capture, item: item, height: thumbHeight)
                }
                // Empty places keep the thumbnails the size they would be with a full row.
                if shown.count < fit {
                    ForEach(0..<(fit - shown.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                }
            }
        }
        .frame(height: thumbHeight + 17)
    }
}

private struct RecentThumbnail: View {
    let capture: CaptureFeature
    let item: RecentCapture
    let height: CGFloat
    @State private var made: CaptureImage?

    init(capture: CaptureFeature, item: RecentCapture, height: CGFloat) {
        self.capture = capture
        self.item = item
        self.height = height
        _made = State(initialValue: capture.thumbnails.cached(item))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            RoundedRectangle(cornerRadius: Deck.Radius.control, style: .continuous)
                .fill(Deck.cardRaised)
                .overlay {
                    // The picture fills the box the shape sets, so it never widens the row.
                    if let made {
                        Image(decorative: made.image, scale: 1).resizable().scaledToFill()
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    Text(item.kind.badge)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Deck.text)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Deck.deck.opacity(0.72)))
                        .padding(6)
                }
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: Deck.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Deck.Radius.control, style: .continuous)
                        .strokeBorder(Deck.hairline, lineWidth: 1))
            Text(CaptureLibrary.timeLabel(item.date)).deckText(.caption).font(.system(size: 11)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture { capture.open(item) }
        .contextMenu {
            Button("Copy") { capture.copy(item) }
            Button("Reveal") { capture.reveal(item) }
            Button("Delete", role: .destructive) { capture.delete(item) }
        }
        .task(id: item.url) {
            made = await capture.thumbnails.image(for: item, maxPixel: 360)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.kind.badge) capture, \(CaptureLibrary.timeLabel(item.date))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Copy") { capture.copy(item) }
        .accessibilityAction(named: "Reveal") { capture.reveal(item) }
        .accessibilityAction(named: "Delete") { capture.delete(item) }
    }
}
