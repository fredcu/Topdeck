// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckSurface

/// The busiest processes, filling its card: a header to sort by (Process, CPU, Memory; the sorted one in the text
/// colour with a ↓), then as many 30 point rows as the height has room for, each with the app's icon (a plain
/// glyph for a process that has none), its name, its CPU with a faint bar of its share behind the figure, and its
/// memory.
struct ProcessTable: View {
    let snapshot: PerformanceFeature.Snapshot
    /// The icon of the app that owns a process.
    var icon: (Int32) -> NSImage? = Self.appIcon

    @Environment(\.deckAccent) private var accent
    @State private var sort = ProcessSort.cpu

    nonisolated static func appIcon(_ pid: Int32) -> NSImage? { NSRunningApplication(processIdentifier: pid)?.icon }

    static let rowHeight: CGFloat = 30
    static let headerHeight: CGFloat = 30
    private static let cpuWidth: CGFloat = 64
    private static let memoryWidth: CGFloat = 80

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Deck.Radius.tile + 2, style: .continuous)
        GeometryReader { space in
            let fit = max(Int((space.size.height - Self.headerHeight) / Self.rowHeight), 0)
            VStack(spacing: 0) {
                header
                ForEach(Array(sort.rows(in: snapshot, limit: fit).enumerated()), id: \.element.id) { index, process in
                    row(process)
                        .overlay(alignment: .top) {
                            if index > 0 { Rectangle().fill(Deck.hairline).frame(height: 1) }
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .monospacedDigit()
        .background(shape.fill(Deck.card))
        .overlay(shape.strokeBorder(Deck.hairline, lineWidth: 1))
        .clipShape(shape)
        .frame(maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                title("Process", .name).padding(.leading, 26).frame(maxWidth: .infinity, alignment: .leading)
                title("CPU", .cpu).frame(width: Self.cpuWidth, alignment: .trailing)
                title("Memory", .memory).frame(width: Self.memoryWidth, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(height: Self.headerHeight - 1)
            Rectangle().fill(Deck.hairline).frame(height: 1)
        }
    }

    private func title(_ text: String, _ key: ProcessSort) -> some View {
        Button {
            sort = key
        } label: {
            Text(sort == key ? "\(text) ↓" : text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(sort == key ? Deck.text : Deck.tertiary)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(text)")
        .accessibilityAddTraits(sort == key ? .isSelected : [])
    }

    private func row(_ process: ProcessUsage) -> some View {
        HStack(spacing: 8) {
            Group {
                if let image = icon(process.pid) {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    DeckIconView(.app, size: 16).foregroundStyle(Deck.tertiary)
                }
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
            Text(process.name).font(.system(size: 13)).foregroundStyle(Deck.text).lineLimit(1)
                .truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            Text(MacFormat.processCPU(process.cpu)).font(.system(size: 12.5)).foregroundStyle(Deck.secondary)
                .frame(width: Self.cpuWidth, alignment: .trailing)
                .background(alignment: .trailing) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(accent.opacity(0.16))
                        .frame(width: Self.cpuWidth * min(max(process.cpu, 0), 100) / 100, height: 16)
                }
            Text(MacFormat.processMemory(process.memory)).font(.system(size: 12.5)).foregroundStyle(Deck.secondary)
                .frame(width: Self.memoryWidth, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.rowHeight)
        .accessibilityElement(children: .combine)
    }
}
