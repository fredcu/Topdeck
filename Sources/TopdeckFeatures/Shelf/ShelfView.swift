// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckSurface

/// The shelf tab: dropped files in a scrolling row. Drag them back out, double-click to preview,
/// or use the context menu to reveal, AirDrop, upload to R2, or remove them.
struct ShelfView: View {
    let shelf: ShelfFeature

    var body: some View {
        if shelf.items.isEmpty {
            DeckEmptyLine("Drop files here")
        } else {
            VStack(spacing: 0) {
                DeckCard(padding: 0) {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: Deck.Metric.gap) {
                            ForEach(shelf.items.reversed()) { item in
                                ShelfItemView(shelf: shelf, item: item)
                            }
                            DropTile()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 20)
                    }
                    .fadingEdges(.horizontal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                Text("^[\(shelf.items.count) item](inflect: true)")
                    .deckText(.caption)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            }
        }
    }
}

extension ShelfFeature {
    /// The second row's buttons: AirDrop everything, and clear the shelf.
    public var headerActions: some View { ShelfActions(shelf: self) }
}

private struct ShelfActions: View {
    let shelf: ShelfFeature

    var body: some View {
        if !shelf.items.isEmpty {
            DeckIconButton(.share, label: "AirDrop All") { shelf.airDrop(shelf.items) }
            DeckIconButton(.trash, label: "Clear") { shelf.removeAll() }
        }
    }
}

/// The empty slot at the end of the row: where the next file goes.
private struct DropTile: View {
    var body: some View {
        VStack(spacing: 8) {
            DeckIconView(.plus, size: 20)
                .foregroundStyle(Deck.tertiary)
                .frame(width: 84, height: 84)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Deck.hairline, lineWidth: 1.5)
                )
            Text("Drop").deckText(.caption)
        }
        .frame(width: 104)
        .accessibilityHidden(true)
    }
}

private struct ShelfItemView: View {
    let shelf: ShelfFeature
    let item: ShelfItem

    var body: some View {
        let url = shelf.url(for: item)
        VStack(spacing: 8) {
            icon(for: url)
                .resizable()
                .scaledToFit()
                .frame(width: 52, height: 52)
                .opacity(url == nil ? 0.35 : 1)
                .frame(width: 84, height: 84)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Deck.cardRaised))
            // One line, middle-truncated, so the extension stays readable (never "Screenshot.p-ng").
            Text(item.name)
                .deckText(.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 104)
            if url == nil {
                Text("Missing").deckText(.caption, color: Deck.stop)
            } else if let status {
                UploadStatusView(status: status)
            }
        }
        .frame(width: 104)
        .contentShape(Rectangle())
        .onDrag { url.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
        .onTapGesture(count: 2) { shelf.quickLook(item) }
        .contextMenu {
            Button("Quick Look") { shelf.quickLook(item) }.disabled(url == nil)
            Button("Show in Finder") { shelf.reveal(item) }.disabled(url == nil)
            Button("AirDrop") { shelf.airDrop([item]) }.disabled(url == nil)
            if let uploads = shelf.uploads, uploads.isOffered {
                uploadMenu(uploads, url: url)
            }
            Divider()
            Button("Remove from Shelf") { shelf.remove(item) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityName(url: url))
        .accessibilityAction(named: "Quick Look") { shelf.quickLook(item) }
        .accessibilityAction(named: "Remove from Shelf") { shelf.remove(item) }
    }

    private var status: R2Uploads.Status? { shelf.uploads?.statuses[item.id] }

    @ViewBuilder
    private func uploadMenu(_ uploads: R2Uploads, url: URL?) -> some View {
        switch status {
        case .uploading:
            Button("Cancel Upload") { uploads.cancel(item) }
        case .uploaded(let link?):
            Button("Copy R2 Link") { uploads.copyLink(link) }
            Button("Upload to R2 Again") { upload(url, with: uploads, replacing: true) }.disabled(url == nil)
        case .failed(let reason, alreadyExists: true):
            Text(reason)
            Button("Replace in R2") { upload(url, with: uploads, replacing: true) }.disabled(url == nil)
        case .failed(let reason, alreadyExists: false):
            Text(reason)
            Button("Try Upload Again") { upload(url, with: uploads) }.disabled(url == nil)
        case .uploaded(nil), nil:
            Button("Upload to R2") { upload(url, with: uploads) }.disabled(url == nil)
        }
    }

    private func upload(_ url: URL?, with uploads: R2Uploads, replacing: Bool = false) {
        guard let url else { return }
        uploads.upload(item, from: url, replacing: replacing)
    }

    private func accessibilityName(url: URL?) -> String {
        guard url != nil else { return "\(item.name), missing" }
        guard let status else { return item.name }
        return "\(item.name), \(status.label)"
    }

    private func icon(for url: URL?) -> Image {
        guard let url else { return Image(systemName: "questionmark.folder") }
        return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
    }
}

/// How a file's upload to R2 is going, under its name.
private struct UploadStatusView: View {
    let status: R2Uploads.Status

    var body: some View {
        switch status {
        case .uploading(let fraction):
            DeckBar(fraction).frame(width: 52)
        case .uploaded:
            DeckIconView(.check, size: 13).foregroundStyle(Deck.go)
        case .failed(let reason, _):
            Text("Failed").deckText(.caption, color: Deck.stop).help(reason)
        }
    }
}

extension R2Uploads.Status {
    /// For VoiceOver, after the file's name.
    var label: String {
        switch self {
        case .uploading(let fraction): "uploading, \(Int(fraction * 100)) percent"
        case .uploaded: "uploaded to R2"
        case .failed(let reason, _): "upload failed: \(reason)"
        }
    }
}
