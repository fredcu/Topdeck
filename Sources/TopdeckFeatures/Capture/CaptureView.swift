// SPDX-License-Identifier: MIT
import SwiftUI

/// The capture tab: a tile per tool, and the colours picked lately, a click from the clipboard again.
struct CaptureView: View {
    let capture: CaptureFeature

    var body: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(CaptureFeature.Tool.allCases) { tool in
                    tile(tool)
                }
            }
            if !capture.colors.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(capture.colors, id: \.self) { code in
                            swatch(code)
                        }
                    }
                }
                .fadingEdges(.horizontal)
            }
        }
        .padding(.vertical, 6)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func tile(_ tool: CaptureFeature.Tool) -> some View {
        Button {
            capture.run(tool)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tool.symbol).font(.system(size: 12, weight: .medium)).frame(width: 16)
                Text(tool.title).font(.caption.weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    private func swatch(_ code: String) -> some View {
        Button {
            capture.copyColor(code)
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(ColorCode.rgb(code)?.color ?? .clear)
                    .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                    .frame(width: 12, height: 12)
                Text(code).font(.caption2.monospaced())
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy \(code)")
    }
}
