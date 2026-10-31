// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

extension CaptureFeature.Tool {
    /// The tile's label, as the Tools board words it.
    var tileTitle: String {
        switch self {
        case .pin: "Pin Image"
        case .text: "Copy Text"
        default: title
        }
    }

    var icon: DeckIcon {
        switch self {
        case .screenshot: .capture
        case .scrolling: .scrollingCapture
        case .text: .recognizeText
        case .qrCode: .qrCode
        case .color: .colorPicker
        case .pin: .pin
        }
    }

    /// The tiles' order on the board.
    static let tiles: [CaptureFeature.Tool] = [.screenshot, .scrolling, .pin, .text, .qrCode, .color]
}

/// The capture tools: a tile per tool, and the colours picked lately in a card, a click from the
/// clipboard again. `compact` is the shorter layout for the smallest deck.
struct CaptureView: View {
    let capture: CaptureFeature
    var compact = false

    var body: some View {
        VStack(spacing: Deck.Metric.gap) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(CaptureFeature.Tool.tiles) { tool in tile(tool) }
            }
            if !capture.colors.isEmpty { colors }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func tile(_ tool: CaptureFeature.Tool) -> some View {
        Button {
            capture.run(tool)
        } label: {
            Group {
                VStack(alignment: .leading, spacing: 0) {
                    DeckIconView(tool.icon)
                    Spacer(minLength: 0)
                    Text(tool.tileTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
            }
            .foregroundStyle(Deck.text)
            .padding(.horizontal, 11)
            .padding(.vertical, compact ? 6 : 10)
            .frame(maxWidth: .infinity, minHeight: compact ? 46 : 62, maxHeight: compact ? 46 : 62, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Deck.Radius.tile, style: .continuous).fill(Deck.cardRaised))
            .contentShape(RoundedRectangle(cornerRadius: Deck.Radius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.tileTitle)
    }

    /// The last colours, newest first, and the newest one's code; clicking one copies it.
    private var colors: some View {
        DeckCard(padding: compact ? 10 : 12) {
            VStack(spacing: Deck.Metric.gap) {
                HStack {
                    Text("Colors").deckText(.body)
                    Spacer(minLength: 0)
                    Button(action: capture.clearColors) { DeckIconView(.close, size: 13) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Deck.secondary)
                        .frame(width: 24, height: 24)
                        .help("Clear colors")
                        .accessibilityLabel("Clear colors")
                }
                HStack(spacing: Deck.Metric.gap) {
                    ForEach(capture.colors, id: \.self) { code in swatch(code) }
                    Spacer(minLength: 0)
                    if let newest = capture.colors.first { Text(newest).deckText(.command).lineLimit(1) }
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(maxHeight: .infinity)
    }

    private func swatch(_ code: String) -> some View {
        Button {
            capture.copyColor(code)
        } label: {
            Circle().fill(ColorCode.rgb(code)?.color ?? .clear).frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Deck.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(code)
        .accessibilityLabel("Copy \(code)")
    }
}
