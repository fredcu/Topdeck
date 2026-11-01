// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckSurface
import UniformTypeIdentifiers

/// The shelf space: dropped files as large tiles, with the places to send them beside. Drag a tile out
/// as a file, or onto a target to act on it. Click ticks, double-click opens, Space looks, and the context
/// menu keeps reveal, AirDrop, upload to R2 and remove. Empty, a drop zone stands where the tiles go.
struct ShelfView: View {
    let shelf: ShelfFeature
    /// How many files are already being dragged over the zone or the tiles, for a picture of that.
    var incoming: Int?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Deck.Metric.gap) {
            if shelf.items.isEmpty {
                ShelfDropZone(shelf: shelf, incoming: incoming)
            } else {
                ShelfGrid(shelf: shelf, incoming: incoming)
            }
            VStack(spacing: 8) {
                ForEach(ShelfFeature.Target.allCases, id: \.self) { ShelfTargetView(shelf: shelf, target: $0) }
            }
            .frame(width: 172)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.space) {
            guard let item = shelf.items.first(where: { shelf.selected.contains($0.id) }) else { return .ignored }
            shelf.quickLook(item)
            return .handled
        }
    }
}

/// The tiles, which keep files dragged onto them.
private struct ShelfGrid: View {
    let shelf: ShelfFeature
    @State private var incoming: Int?
    @Environment(\.deckAccent) private var accent

    init(shelf: ShelfFeature, incoming: Int?) {
        self.shelf = shelf
        _incoming = State(initialValue: incoming)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Deck.Radius.card, style: .continuous)
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(shelf.items.reversed()) { ShelfTile(shelf: shelf, item: $0) }
            }
        }
        .fadingEdges(atStart: false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The outline stands just outside the area, so tiles at its edge don't touch it.
        .background { if incoming != nil { shape.fill(accent.tint(0.07)).padding(-5) } }
        .overlay {
            if let incoming {
                shape.strokeBorder(accent, lineWidth: 1.5).padding(-5)
                // Low in the area, where the tiles have left room.
                GeometryReader { proxy in
                    HStack(spacing: 6) {
                        DeckIconView(.plus, size: 13)
                        Text("Add ^[\(incoming) file](inflect: true)")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Deck.onAccent)
                    .padding(.horizontal, 13)
                    .frame(height: 30)
                    .background(Capsule().fill(accent).shadow(color: .black.opacity(0.4), radius: 9, y: 4))
                    .position(x: proxy.size.width / 2, y: proxy.size.height * 0.72)
                }
                .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], delegate: ShelfDropDelegate(shelf: shelf, incoming: $incoming))
    }
}

/// The empty shelf: a dashed zone with the illustration, a line saying what it is for and the way to pick
/// files by hand. Files dragged over it turn it into the accent, and dropping keeps them.
private struct ShelfDropZone: View {
    let shelf: ShelfFeature
    @State private var incoming: Int?
    @Environment(\.deckAccent) private var accent

    /// The zone's height from which the line has room: the smallest deck's is 247, the usual deck's 337.
    private static let heightForLine: CGFloat = 270

    init(shelf: ShelfFeature, incoming: Int?) {
        self.shelf = shelf
        _incoming = State(initialValue: incoming)
    }

    var body: some View {
        let hot = incoming != nil
        let shape = RoundedRectangle(cornerRadius: Deck.Radius.card, style: .continuous)
        // The explanatory line is the first to go where the zone is too short for it.
        GeometryReader { proxy in
            content(hot: hot, line: proxy.size.height >= Self.heightForLine)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(hot ? accent.tint(0.08) : .clear))
        .overlay {
            shape.strokeBorder(
                hot ? accent : Deck.secondary.opacity(0.22),
                style: StrokeStyle(lineWidth: 1.5, dash: hot ? [10, 3] : [6, 5]))
        }
        .contentShape(shape)
        .onDrop(of: [.fileURL], delegate: ShelfDropDelegate(shelf: shelf, incoming: $incoming))
    }

    private func content(hot: Bool, line: Bool) -> some View {
        VStack(spacing: 0) {
            ShelfTrayArt(detail: true, hot: hot).frame(width: 132, height: 96)
            Text(hot ? "Let go to keep them here" : "Drop files here")
                .deckText(.item).lineLimit(1)
                .padding(.top, 16)
            if !hot {
                if line {
                    Text("Keep files at hand while you switch apps. Drag them onto the notch from anywhere.")
                        .deckText(.body, color: Deck.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 270)
                        .padding(.top, 5)
                }
                Button(action: shelf.chooseFiles) {
                    HStack(spacing: 6) {
                        DeckIconView(.plus, size: 13)
                        Text("Choose Files…")
                    }
                }
                .buttonStyle(.deck(.outline, slot: true))
                .padding(.top, 14)
            }
        }
    }
}

/// Keeps the files dragged onto its view, and says how many are over it.
@MainActor
private struct ShelfDropDelegate: DropDelegate {
    let shelf: ShelfFeature
    @Binding var incoming: Int?

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) { incoming = info.itemProviders(for: [.fileURL]).count }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func dropExited(info: DropInfo) { incoming = nil }

    func performDrop(info: DropInfo) -> Bool {
        incoming = nil
        let providers = info.itemProviders(for: [.fileURL])
        Task {
            var urls: [URL] = []
            for provider in providers { if let url = await provider.droppedFile() { urls.append(url) } }
            shelf.add(urls)
        }
        return true
    }
}

extension ShelfFeature {
    /// The second row's left side: how many files and how big they are. Nil while empty, when the name shows.
    public func headerLeading() -> AnyView? {
        items.isEmpty ? nil : AnyView(ShelfSummary(shelf: self))
    }

    /// The second row's buttons: select several, and clear the shelf.
    public var headerActions: some View { ShelfActions(shelf: self) }
}

private struct ShelfSummary: View {
    let shelf: ShelfFeature

    var body: some View {
        HStack(spacing: 10) {
            Text("^[\(shelf.items.count) item](inflect: true)").deckText(.title).lineLimit(1)
            Text(shelf.sizes.values.reduce(0, +).formatted(.byteCount(style: .file)))
                .deckText(.body, color: Deck.secondary).lineLimit(1)
        }
    }
}

private struct ShelfActions: View {
    let shelf: ShelfFeature

    var body: some View {
        if !shelf.items.isEmpty {
            ShelfAddButton(shelf: shelf)
            Button("Select") {
                if shelf.isSelecting { shelf.finishSelecting() } else { shelf.isSelecting = true }
            }
            .buttonStyle(.deckPill(on: shelf.isSelecting))
            Button("Clear", action: shelf.removeAll).buttonStyle(.deckPill())
        }
    }
}

/// Add Files…, as the illustration's small version.
private struct ShelfAddButton: View {
    let shelf: ShelfFeature
    @State private var hovering = false

    var body: some View {
        Button(action: shelf.chooseFiles) {
            ShelfTrayArt(detail: false)
                .frame(width: 18, height: 18)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Deck.control : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Add Files…")
        .accessibilityLabel("Add Files…")
    }
}

// MARK: Targets

/// One of the four places to send files. Click acts on the ticked tiles, or on all; drop tiles or files from
/// anywhere on it to act on those.
private struct ShelfTargetView: View {
    let shelf: ShelfFeature
    let target: ShelfFeature.Target
    @State private var over = false
    @Environment(\.deckAccent) private var accent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Deck.Radius.tile, style: .continuous)
        let available = shelf.isAvailable(target)
        let label = HStack(spacing: 10) {
            DeckIconView(icon, size: 16).foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.tint(0.2)))
            Text(target.title).deckText(.body, color: Deck.text).fontWeight(.semibold).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(over ? accent.tint(0.16) : Deck.card))
        .overlay(shape.strokeBorder(over ? accent : Deck.hairline, lineWidth: 1))
        .contentShape(shape)
        Group {
            if shelf.items.isEmpty {
                label  // nothing to act on by a click, but files can still be dropped here
            } else {
                Button {
                    shelf.perform(target, on: shelf.actionURLs)
                } label: {
                    label
                }
                .buttonStyle(.plain)
                .disabled(!available)
            }
        }
        .opacity(available ? 1 : 0.4)
        .onDrop(of: [.fileURL], isTargeted: $over) { providers in
            guard available else { return false }
            Task {
                var urls: [URL] = []
                for provider in providers { if let url = await provider.droppedFile() { urls.append(url) } }
                shelf.perform(target, on: urls)
            }
            return true
        }
        .accessibilityLabel(target.title)
    }

    private var icon: DeckIcon {
        switch target {
        case .airDrop: .airDrop
        case .upload: .upload
        case .note: .note
        case .openWith: .openWith
        }
    }

    private var tint: Color {
        switch target {
        case .airDrop: Deck.Accent.now
        case .upload: Deck.Accent.tools
        case .note: Deck.Accent.clipboard
        case .openWith: Deck.secondary
        }
    }
}

extension NSItemProvider {
    /// The file a drop carries, if it is one.
    @MainActor func droppedFile() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}

// MARK: Tiles

private struct ShelfTile: View {
    let shelf: ShelfFeature
    let item: ShelfItem
    @State private var made: NSImage?
    @Environment(\.deckAccent) private var accent
    private static let thumbSize = CGSize(width: 180, height: 120)

    var body: some View {
        let url = shelf.url(for: item)
        let ticked = shelf.selected.contains(item.id)
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        VStack(alignment: .leading, spacing: 1) {
            art(url)
                .frame(maxWidth: .infinity)
                .aspectRatio(1.5, contentMode: .fit)
                .clipShape(shape)
                .overlay(shape.strokeBorder(accent, lineWidth: ticked ? 2 : 0))
                .overlay(alignment: .topTrailing) {
                    if shelf.isSelecting {
                        DeckIconView(ticked ? .check : .app, size: 14)
                            .foregroundStyle(ticked ? Deck.onAccent : Deck.text)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(ticked ? accent : Deck.deck.opacity(0.5)))
                            .padding(6)
                    }
                }
                .padding(.bottom, 4)
            // One line, middle-truncated, so the extension stays readable (never "Screenshot.p-ng").
            Text(item.name).deckText(.body).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            if url == nil {
                Text("Missing").deckText(.caption, color: Deck.stop).lineLimit(1)
            } else if let status {
                UploadStatusView(status: status)
            } else {
                Text(detail(url)).deckText(.caption).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onDrag { url.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
        .onTapGesture(count: 2) { if let url { NSWorkspace.shared.open(url) } }
        .onTapGesture { shelf.select(item, extend: NSEvent.modifierFlags.contains(.command)) }
        .task(id: url) {
            guard let url else { return }
            made = await shelf.thumbnails.image(for: url, size: Self.thumbSize, scale: 2)
        }
        .contextMenu {
            Button("Open") { if let url { NSWorkspace.shared.open(url) } }.disabled(url == nil)
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
        .accessibilityAddTraits(ticked ? .isSelected : [])
        .accessibilityAction(named: "Quick Look") { shelf.quickLook(item) }
        .accessibilityAction(named: "Remove from Shelf") { shelf.remove(item) }
    }

    /// The thumbnail, or the file's kind colour with its extension.
    @ViewBuilder private func art(_ url: URL?) -> some View {
        if let thumbnail = made ?? url.flatMap({ shelf.thumbnails.cached(for: $0, size: Self.thumbSize) }) {
            ZStack {
                Deck.cardRaised
                if ShelfKind(url).isImage {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(nsImage: thumbnail).resizable().scaledToFit().padding(6)
                }
            }
        } else {
            let kind = ShelfKind(url)
            ZStack {
                LinearGradient(
                    colors: [kind.tint, kind.tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(kind.label)
                    .font(.system(size: 13, weight: .bold)).tracking(0.5)
                    .foregroundStyle(Deck.text.opacity(0.8))
                    .opacity(url == nil ? 0.4 : 1)
            }
            .background(Deck.body)
        }
    }

    /// "PDF, 2.4 MB".
    private func detail(_ url: URL?) -> String {
        let kind = ShelfKind(url).label
        guard let size = shelf.sizes[item.id] else { return kind }
        return "\(kind), \(size.formatted(.byteCount(style: .file)))"
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
}

/// What a file is, for its tile: the extension to print and the colour to print it on.
struct ShelfKind {
    let label: String
    let tint: Color
    let isImage: Bool

    init(_ url: URL?) {
        guard let url else {
            (label, tint, isImage) = ("?", Deck.Kind.other, false)
            return
        }
        let type =
            (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        let ext = url.pathExtension.uppercased()
        label = type?.conforms(to: .folder) == true ? "FOLDER" : ext.isEmpty ? "FILE" : String(ext.prefix(5))
        isImage = type?.conforms(to: .image) == true
        tint =
            switch type {
            case let type? where type.conforms(to: .image): Deck.Kind.image
            case let type? where type.conforms(to: .pdf) || type.conforms(to: .presentation): Deck.Kind.document
            case let type? where type.conforms(to: .spreadsheet): Deck.Kind.sheet
            case let type? where type.conforms(to: .movie): Deck.Kind.video
            case let type? where type.conforms(to: .audio): Deck.Kind.audio
            case let type? where type.conforms(to: .archive) || type.conforms(to: .diskImage): Deck.Kind.archive
            case let type? where type.conforms(to: .sourceCode): Deck.Kind.code
            case let type? where type.conforms(to: .text): Deck.Kind.document
            default: Deck.Kind.other
            }
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
