// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

/// The colour picker's popover on the Tools screen: pick one from the screen, and the ones picked lately,
/// a click from the clipboard again.
struct ColorPopover: View {
    let capture: CaptureFeature
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Deck.Metric.gap) {
            HStack {
                Button("Pick Colour") {
                    done()
                    capture.run(.color)
                }
                .buttonStyle(.deck(.primary))
                Spacer(minLength: 0)
                if !capture.colors.isEmpty {
                    Button(action: capture.clearColors) { DeckIconView(.close, size: 13) }
                        .buttonStyle(.deckIcon())
                        .help("Clear colors")
                        .accessibilityLabel("Clear colors")
                }
            }
            if !capture.colors.isEmpty {
                HStack(spacing: Deck.Metric.gap) {
                    ForEach(capture.colors, id: \.self) { code in swatch(code) }
                    Spacer(minLength: 0)
                    if let newest = capture.colors.first { Text(newest).deckText(.command).lineLimit(1) }
                }
            }
        }
        .padding(Deck.Metric.cardPadding)
        .frame(width: 260)
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
