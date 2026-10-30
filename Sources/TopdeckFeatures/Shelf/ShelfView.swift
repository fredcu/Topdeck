// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

/// The shelf tab: dropped files in a scrolling row. Drag them back out, double-click to preview,
/// or use the context menu to reveal, AirDrop, upload to R2, or remove them.
struct ShelfView: View {
    let shelf: ShelfFeature

    var body: some View {
        if shelf.items.isEmpty {
            VStack(spacing: 8) {
                FeatureUnavailableView(
                    symbol: "tray.and.arrow.down",
                    title: "Drop files here",
                    message: "Drag files onto the notch to keep them handy, then drag them back out when you need them."
                )
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 8) {
                        ForEach(shelf.items.reversed()) { item in
                            ShelfItemView(shelf: shelf, item: item)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .fadingEdges(.horizontal)
                HStack(spacing: 12) {
                    Text(shelf.items.count == 1 ? "1 item" : "\(shelf.items.count) items")
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Button("AirDrop All") { shelf.airDrop(shelf.items) }
                    Button("Clear") { shelf.removeAll() }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .lineLimit(1)
            }
        }
    }
}

private struct ShelfItemView: View {
    let shelf: ShelfFeature
    let item: ShelfItem

    var body: some View {
        let url = shelf.url(for: item)
        VStack(spacing: 4) {
            icon(for: url)
                .resizable()
                .frame(width: 44, height: 44)
                .opacity(url == nil ? 0.35 : 1)
            // One line, middle-truncated, so the extension stays readable (never "Screenshot.p-ng").
            Text(item.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
            if url == nil {
                Text("Missing").font(.caption2.bold()).foregroundStyle(.orange)
            } else if let status {
                UploadStatusView(status: status)
            }
        }
        .frame(width: 76)
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
            ProgressView(value: fraction).progressViewStyle(.linear).controlSize(.mini).frame(width: 44)
        case .uploaded:
            Image(systemName: "checkmark.icloud").font(.caption2).foregroundStyle(.green)
        case .failed(let reason, _):
            Text("Failed").font(.caption2.bold()).foregroundStyle(.orange).help(reason)
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
