// SPDX-License-Identifier: MIT
import AppKit
import Observation
import QuickLookUI
import SwiftUI
import TopdeckCore
import UniformTypeIdentifiers

/// A file on the shelf, kept as a bookmark so it follows renames and moves.
public struct ShelfItem: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var bookmark: Data
    public var name: String
}

/// Files dropped on the notch, saved across launches. A file that disappears stays on the shelf,
/// marked missing, until the user removes it: nothing is dropped silently.
@MainActor
@Observable
public final class ShelfFeature: NotchFeature {
    public let id = FeatureID.shelf
    public var phase: FeaturePhase = .stopped {
        didSet { if phase == .foreground { refresh() } }
    }
    public private(set) var items: [ShelfItem] = []
    /// Where each file is now. An item without a location is missing.
    public private(set) var locations: [ShelfItem.ID: URL] = [:]
    /// The size of each file now, in bytes; a folder or a missing file has none.
    public private(set) var sizes: [ShelfItem.ID: Int] = [:]
    /// The tiles ticked. A click ticks one; in select mode a click toggles.
    public var selected: Set<ShelfItem.ID> = []
    public var isSelecting = false
    /// Raised when files land on the shelf.
    @ObservationIgnored public var onActivity: ((Activity) -> Void)?
    /// Uploads to Cloudflare R2, offered from each file's menu.
    @ObservationIgnored public var uploads: R2Uploads?
    /// Raised before the file panel opens, so the deck can get out of its way.
    @ObservationIgnored public var onBegin: (() -> Void)?
    /// Starts a note with this text; the app wires it to Notes.
    @ObservationIgnored public var addToNote: ((String) -> Void)?
    /// The pictures on the tiles, made off the main thread and kept in memory.
    @ObservationIgnored let thumbnails = ShelfThumbnails()

    // ponytail: a fixed cap keeps the shelf and its bookmark checks bounded; make it a setting if asked.
    static let capacity = 100
    /// A sandboxed build (the App Store edition) may only reach a dropped file again through a
    /// security-scoped bookmark, and holds access to each file while it's on the shelf.
    static let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    /// Where the file panel last picked from, as a path.
    static let lastFolderKey = "shelfLastFolder"
    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let quickLook = QuickLookSource()
    /// Files whose security scope is open, in a sandboxed build.
    @ObservationIgnored private var accessing: [ShelfItem.ID: URL] = [:]

    public init(storeURL: URL = AppSupport.file("shelf.json"), defaults: UserDefaults = .standard) {
        self.storeURL = storeURL
        self.defaults = defaults
        if let data = try? Data(contentsOf: storeURL) {
            items = (try? JSONDecoder().decode([ShelfItem].self, from: data)) ?? []
        }
        refresh()
    }

    public var view: some View { ShelfView(shelf: self) }

    /// Adds dropped files, skipping ones already on the shelf. Returns whether anything was added.
    @discardableResult
    public func add(_ urls: [URL]) -> Bool {
        var known = Set(locations.values.map(\.standardizedFileURL))
        var added: [ShelfItem] = []
        for url in urls where url.isFileURL && !known.contains(url.standardizedFileURL) {
            guard let bookmark = try? url.bookmarkData(options: Self.bookmarkOptions) else { continue }
            let item = ShelfItem(bookmark: bookmark, name: url.lastPathComponent)
            added.append(item)
            locations[item.id] = url
            known.insert(url.standardizedFileURL)
        }
        guard !added.isEmpty else { return false }
        items = Array((items + added).suffix(Self.capacity))
        measure()
        save()
        let title = added.count == 1 ? "1 file" : "\(added.count) files"
        onActivity?(Activity(feature: .shelf, symbol: "tray.and.arrow.down.fill", title: title, duration: .seconds(2)))
        return true
    }

    /// Asks for files and folders and keeps them, starting where the last pick was.
    public func chooseFiles() {
        onBegin?()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.directoryURL = panelFolder
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        rememberFolder(of: panel.urls)
        add(panel.urls)
    }

    /// Where the file panel opens: the folder of the last pick, if it is still there, else Downloads.
    var panelFolder: URL? {
        var isFolder: ObjCBool = false
        if let path = defaults.string(forKey: Self.lastFolderKey),
            FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue
        {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    /// Remembers the folder a pick came from: a file's folder, or the folder that holds a picked folder.
    func rememberFolder(of urls: [URL]) {
        guard let first = urls.first else { return }
        defaults.set(first.deletingLastPathComponent().path, forKey: Self.lastFolderKey)
    }

    public func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        locations[item.id] = nil
        sizes[item.id] = nil
        selected.remove(item.id)
        uploads?.forget(item.id)
        accessing.removeValue(forKey: item.id)?.stopAccessingSecurityScopedResource()
        save()
    }

    public func removeAll() {
        for item in items { uploads?.forget(item.id) }
        items = []
        locations = [:]
        sizes = [:]
        selected = []
        isSelecting = false
        for url in accessing.values { url.stopAccessingSecurityScopedResource() }
        accessing = [:]
        save()
    }

    /// The file's current location, or nil if it's missing.
    public func url(for item: ShelfItem) -> URL? { locations[item.id] }

    public func quickLook(_ item: ShelfItem) {
        guard let url = url(for: item) else { return }
        quickLook.show(url)
    }

    public func airDrop(_ items: [ShelfItem]) { airDrop(urls: items.compactMap(url(for:))) }

    public func airDrop(urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate()
        service.perform(withItems: urls)
    }

    public func reveal(_ item: ShelfItem) {
        guard let url = url(for: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Finds every file again and renews bookmarks that went stale after a move or rename.
    func refresh() {
        var found: [ShelfItem.ID: URL] = [:]
        var renewed = false
        for index in items.indices {
            var stale = false
            let item = items[index]
            guard
                let url = try? URL(
                    resolvingBookmarkData: item.bookmark, options: Self.resolutionOptions, bookmarkDataIsStale: &stale)
            else { continue }
            if Self.sandboxed, accessing[item.id] == nil, url.startAccessingSecurityScopedResource() {
                accessing[item.id] = url
            }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            found[item.id] = url
            if stale, let fresh = try? url.bookmarkData(options: Self.bookmarkOptions) {
                items[index].bookmark = fresh
                items[index].name = url.lastPathComponent
                renewed = true
            }
        }
        locations = found
        selected.formIntersection(found.keys)
        measure()
        if renewed { save() }
    }

    private func measure() {
        sizes = locations.compactMapValues { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
    }

    // MARK: Selecting

    /// Ticks the tile, alone unless selecting or `extend`, which toggle it among the others.
    public func select(_ item: ShelfItem, extend: Bool = false) {
        if isSelecting || extend {
            if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
        } else {
            selected = [item.id]
        }
    }

    public func finishSelecting() {
        isSelecting = false
        selected = []
    }

    /// The files the targets act on when clicked: the ticked ones, or all when none is ticked.
    public var actionURLs: [URL] {
        let chosen = items.filter { selected.contains($0.id) }
        return (chosen.isEmpty ? items : chosen).compactMap(url(for:))
    }

    // MARK: Targets

    public enum Target: CaseIterable, Sendable {
        case airDrop, upload, note, openWith

        public var title: String {
            switch self {
            case .airDrop: "AirDrop"
            case .upload: "Upload to R2"
            case .note: "Add to Note"
            case .openWith: "Open With"
            }
        }
    }

    /// Whether the target can be used: Upload to R2 needs a bucket and keys.
    public func isAvailable(_ target: Target) -> Bool { target != .upload || uploads?.isSetUp == true }

    /// Does what the target says to these files, which may be on the shelf or dropped straight from elsewhere.
    public func perform(_ target: Target, on urls: [URL]) {
        guard !urls.isEmpty, isAvailable(target) else { return }
        switch target {
        case .airDrop: airDrop(urls: urls)
        case .upload:
            // An upload belongs to a file on the shelf, which is where its progress shows.
            add(urls)
            for url in urls {
                if let item = items.first(where: { locations[$0.id]?.standardizedFileURL == url.standardizedFileURL }) {
                    uploads?.upload(item, from: url)
                }
            }
        case .note: addToNote?(Self.noteText(for: urls))
        case .openWith: OpenWithMenu.show(for: urls)
        }
    }

    /// What a new note starts with: a text file's content, up to 20,000 characters, or else the path.
    nonisolated static func noteText(for urls: [URL]) -> String {
        urls.map { url in
            let isText = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .text) == true
            guard isText, let handle = try? FileHandle(forReadingFrom: url) else { return url.path }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 80_000)) ?? Data()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? url.path : String(text.prefix(20_000))
        }.joined(separator: "\n\n")
    }

    private static var bookmarkOptions: URL.BookmarkCreationOptions { sandboxed ? .withSecurityScope : [] }
    private static var resolutionOptions: URL.BookmarkResolutionOptions { sandboxed ? .withSecurityScope : [] }

    private func save() {
        do {
            try JSONEncoder().encode(items).write(to: storeURL, options: .atomic)
        } catch {
            Log.features.error("Couldn't save the shelf: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Feeds one file to the shared Quick Look panel, independent of the notch's views, so the preview
/// stays open when the notch collapses.
@MainActor
private final class QuickLookSource: NSObject, @preconcurrency QLPreviewPanelDataSource {
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL?
    }
}
