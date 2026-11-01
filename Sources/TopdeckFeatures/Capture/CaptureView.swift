// SPDX-License-Identifier: MIT
import AVFoundation
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
        case .recordWindow: .window
        case .recordScreen: .display
        }
    }

    /// The tile's label, as the Tools board words it.
    var tileTitle: String { self == .screenshot ? "Area" : title }

    /// The tiles of the first row, in the board's order.
    static let tiles: [CaptureFeature.Tool] = [.screenshot, .window, .screen, .scrolling, .text]
}

/// One cell of a toolbar: a line icon over a name. A tool whose action isn't there is dimmed, and its
/// `.help` says so. `recording` marks a cell that records, with a red dot on its icon.
struct ToolCell: View {
    let title: String
    let icon: DeckIcon
    var tint: Color = Deck.text
    var recording = false
    var disabledHelp: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                DeckIconView(icon, size: 19)
                    .foregroundStyle(tint)
                    .overlay(alignment: .topTrailing) {
                        if recording {
                            Circle().fill(Deck.stop).frame(width: 7, height: 7)
                                .padding(2).background(Circle().fill(Deck.card))
                                .offset(x: 7, y: -4)
                        }
                    }
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Deck.text)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabledHelp != nil)
        .opacity(disabledHelp == nil ? 1 : 0.45)
        .help(disabledHelp ?? "")
        .accessibilityLabel(title)
    }
}

/// A card cut into equal cells by hairlines: the Tools screen's toolbar.
struct ToolBar<Content: View>: View {
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Deck.Radius.tile + 2, style: .continuous)
        HStack(spacing: 0) { content }
            .frame(height: height)
            .background(shape.fill(Deck.card))
            .overlay(shape.strokeBorder(Deck.hairline, lineWidth: 1))
            .clipShape(shape)
    }
}

/// The hairline between two cells of a toolbar.
struct ToolBarDivider: View {
    var body: some View { Rectangle().fill(Deck.hairline).frame(width: 1) }
}

/// The capture tools as two toolbars, and the captures kept lately under them.
struct CaptureView: View {
    let capture: CaptureFeature
    var compact = false

    var body: some View {
        VStack(spacing: Deck.Metric.gap) {
            ToolBar(height: compact ? 56 : 64) {
                ForEach(Array(CaptureFeature.Tool.tiles.enumerated()), id: \.element) { index, tool in
                    if index > 0 { ToolBarDivider() }
                    ToolCell(title: tool.tileTitle, icon: tool.icon, tint: accent) { capture.run(tool) }
                }
            }
            ToolBar(height: compact ? 56 : 64) {
                RecordCell(capture: capture, tool: .recordWindow)
                ToolBarDivider()
                RecordCell(capture: capture, tool: .recordScreen)
                ToolBarDivider()
                ToolCell(title: "Edit Video", icon: .film, tint: accent) { capture.editVideo() }
                ToolBarDivider()
                RecordingOptionToggles(recorder: capture.recorder, compact: compact)
            }
            RecentCaptures(capture: capture, compact: compact)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @Environment(\.deckAccent) private var accent
}

/// Record Window or Record Screen: a cell that starts the recording, and ends it while one is on.
struct RecordCell: View {
    let capture: CaptureFeature
    let tool: CaptureFeature.Tool

    var body: some View {
        let active = capture.recorder.isActive
        ToolCell(
            title: active ? "Stop" : tool.tileTitle, icon: tool.icon, tint: active ? Deck.stop : Deck.text,
            recording: !active
        ) {
            capture.run(tool)
        }
        .accessibilityLabel(active ? "Stop recording" : tool.title)
    }
}

/// What a recording takes along, as three small toggles in the toolbar's last cell: the Mac's sound, the
/// microphone, and a ring where the mouse clicks. Remembered between recordings; fixed while one is on.
struct RecordingOptionToggles: View {
    @Bindable var recorder: RecordingController
    var compact = false

    var body: some View {
        VStack(spacing: 3) {
            toggle("System audio", .volume, $recorder.options.systemAudio)
            toggle("Microphone", .microphone, $recorder.options.microphone)
            toggle(
                "Show clicks", .cursor, $recorder.options.showClicks, help: "Show clicks, in screen recordings only")
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .disabled(recorder.isActive)
        .opacity(recorder.isActive ? 0.45 : 1)
    }

    private func toggle(_ title: String, _ icon: DeckIcon, _ isOn: Binding<Bool>, help: String? = nil) -> some View {
        OptionToggle(title: title, icon: icon, isOn: isOn, height: compact ? 16 : 17)
            .help(help ?? title)
    }
}

private struct OptionToggle: View {
    let title: String
    let icon: DeckIcon
    @Binding var isOn: Bool
    let height: CGFloat
    @Environment(\.deckAccent) private var accent

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            DeckIconView(icon, size: 11)
                .foregroundStyle(isOn ? accent : Deck.tertiary)
                .frame(width: 26, height: height)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(
                        isOn ? accent.tint(0.18) : Deck.cardRaised)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Thumbnails of the newest captures in a grid: as many rows as fit, each picture with its time. Click
/// opens one, drag takes the file out, and the context menu copies, reveals or deletes it.
struct RecentCaptures: View {
    let capture: CaptureFeature
    var compact = false

    static let gap: CGFloat = 10
    /// A thumbnail's caption: the gap above it and its line.
    static let caption: CGFloat = 19

    /// The grid at `size`: the compact deck takes three columns, the others four.
    static func grid(in size: CGSize, compact: Bool) -> (columns: Int, rows: Int, thumb: CGSize) {
        let columns = compact ? 3 : 4
        let width = max(0, (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns))
        let thumb = CGSize(width: width, height: width * 10 / 16)
        let rows = max(1, Int((size.height + gap) / (thumb.height + caption + gap)))
        return (columns, rows, thumb)
    }

    var body: some View {
        GeometryReader { space in
            let grid = Self.grid(in: space.size, compact: compact)
            let shown = Array(capture.recents.prefix(grid.columns * grid.rows))
            VStack(alignment: .leading, spacing: Self.gap) {
                ForEach(0..<grid.rows, id: \.self) { row in
                    HStack(alignment: .top, spacing: Self.gap) {
                        ForEach(0..<grid.columns, id: \.self) { column in
                            let index = row * grid.columns + column
                            // An empty place keeps the thumbnails the size they would be with a full row.
                            if index < shown.count {
                                RecentThumbnail(capture: capture, item: shown[index], height: grid.thumb.height)
                            } else {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct RecentThumbnail: View {
    let capture: CaptureFeature
    let item: RecentCapture
    let height: CGFloat
    @State private var made: CaptureImage?
    @State private var duration: TimeInterval?

    init(capture: CaptureFeature, item: RecentCapture, height: CGFloat) {
        self.capture = capture
        self.item = item
        self.height = height
        _made = State(initialValue: capture.thumbnails.cached(item))
    }

    /// A dark pill at the bottom-left of a recording or a GIF: a play glyph and the length, or "GIF".
    private var playPill: some View {
        HStack(spacing: 4) {
            DeckIconView(.play, size: 8)
            if let duration {
                Text(formatTime(duration)).font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            } else if item.kind == .gif {
                Text("GIF").font(.system(size: 10.5, weight: .semibold))
            }
        }
        .foregroundStyle(Deck.text)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(0.6)))
        .padding(6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Deck.cardRaised)
                .overlay {
                    // The picture fills the box the shape sets, so it never widens the row.
                    if let made {
                        Image(decorative: made.image, scale: 1).resizable().scaledToFill()
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if item.kind != .png { playPill }
                }
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
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
            if item.kind.isVideo {
                let length = try? await AVURLAsset(url: item.url).load(.duration).seconds
                duration = length.flatMap { $0.isFinite ? $0 : nil }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.kind.badge) capture, \(CaptureLibrary.timeLabel(item.date))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Copy") { capture.copy(item) }
        .accessibilityAction(named: "Reveal") { capture.reveal(item) }
        .accessibilityAction(named: "Delete") { capture.delete(item) }
    }
}
