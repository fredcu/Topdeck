// SPDX-License-Identifier: MIT
import AppKit
import ImageIO
import Observation
import SwiftUI
import TopdeckCore

/// Something copied: text, a link, an image, or files.
public struct ClipItem: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, link, image, files }

    public var id = UUID()
    public var kind: Kind
    /// The text or the link; for files, their paths, one per line.
    public var text: String
    /// The text's formatting as it was copied, RTF or HTML by pasteboard type; nil for plain text.
    public var rich: [String: Data]?
    /// The app it was copied in, by name.
    public var source: String?
    public var copied: Date
    /// Favorites stay, whatever the history's length, until removed.
    public var favorite = false

    /// A file's paths, for `.files`.
    var paths: [String] { kind == .files ? text.split(separator: "\n").map(String.init) : [] }
}

/// Whether macOS lets Topdeck read what's copied. Since macOS 15.4 an app that reads the
/// clipboard on its own asks first, until the user allows it in System Settings.
public enum ClipboardAccess: Equatable, Sendable {
    /// It hasn't asked yet.
    case notDetermined
    /// It asks every time: allowed only in Privacy & Security › Paste from Other Apps.
    case asks
    case denied
    case allowed
}

/// Clipboard history: text, links, images, and files you copy, kept on this Mac, newest first,
/// searchable, and one click from the clipboard again.
///
/// macOS has no "clipboard changed" event, so while recording this checks the pasteboard's change
/// count on a timer: the app's one deliberate poll. It's off until the user turns it on, reads
/// only a counter until something changes, and stops with the notch (sleep, display sleep, lock).
/// Nothing marked secret or temporary is kept, nor anything copied in a password manager or in an
/// app the user skips (`ClipboardRules`). Picking an item can paste it into the app in front, as
/// plain text if the user likes, and links can lose their tracking parameters (`LinkCleaner`).
@MainActor
@Observable
public final class ClipboardFeature: NotchFeature {
    public let id = FeatureID.clipboard
    public var phase: FeaturePhase = .stopped {
        didSet { if phase != oldValue { update() } }
    }
    /// Newest first.
    public private(set) var items: [ClipItem] = []
    /// Per-feature setting: keeping a history at all. Off until the user turns it on.
    public private(set) var isRecording: Bool {
        didSet { defaults.set(isRecording, forKey: Self.recordingKey) }
    }
    public private(set) var access = ClipboardAccess.notDetermined
    /// Picking an item also pastes it into the app in front. Needs Accessibility access.
    public var pastesAfterPicking: Bool {
        didSet { defaults.set(pastesAfterPicking, forKey: Self.pastesKey) }
    }
    /// Picking an item leaves its formatting behind. Option-click does this for one item.
    public var pastesAsPlainText: Bool {
        didSet { defaults.set(pastesAsPlainText, forKey: Self.plainTextKey) }
    }
    /// Copied links lose their tracking parameters on the way into the history.
    public var cleansLinks: Bool {
        didSet { defaults.set(cleansLinks, forKey: Self.cleansLinksKey) }
    }
    /// Bundle IDs of the apps whose copies the user chose to skip, in the order they were added.
    public private(set) var ignoredApps: [String] {
        didSet { defaults.set(ignoredApps, forKey: Self.ignoredAppsKey) }
    }
    /// Set when the Clipboard tab opens from its shortcut, so the search field takes the keyboard.
    public var wantsSearch = false
    /// What the search field in the deck's second row asks for.
    public var query = ""
    /// Raised when an item goes back on the clipboard.
    @ObservationIgnored public var onActivity: ((Activity) -> Void)?
    /// Called after the user picks an item, to close the notch.
    @ObservationIgnored public var onPicked: (() -> Void)?

    // ponytail: a half-second check, like other clipboard managers; slower misses quick copies.
    static let interval: DispatchTimeInterval = .milliseconds(500)
    // ponytail: fixed caps keep the history and its disk use bounded; settings if people ask.
    static let capacity = 200
    static let largestText = 1_000_000
    static let largestImage = 20_000_000
    static let largestRich = 500_000
    /// The formatting kept with text, when the copying app offers it.
    static let richTypes: [NSPasteboard.PasteboardType] = [.rtf, .html]
    private static let recordingKey = "clipboard.isRecording"
    private static let pastesKey = "clipboard.pastesAfterPicking"
    private static let plainTextKey = "clipboard.pastesAsPlainText"
    private static let cleansLinksKey = "clipboard.cleansLinks"
    private static let ignoredAppsKey = "clipboard.ignoredApps"

    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private let imagesURL: URL
    /// The app in front, where a copy most likely came from: its bundle ID and name.
    @ObservationIgnored private let frontmostApp: () -> (id: String?, name: String?)
    /// Presses ⌘V in the app in front.
    @ObservationIgnored private let pasteInFront: @MainActor () -> Void
    @ObservationIgnored private var poll: DispatchSourceTimer?
    @ObservationIgnored private var lastChange = 0
    @ObservationIgnored private let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 60
        return cache
    }()

    public convenience init() {
        self.init(
            pasteboard: .general, defaults: .standard, storeURL: AppSupport.file("clipboard.json"),
            imagesURL: AppSupport.file("Clipboard"),
            frontmostApp: {
                let app = NSWorkspace.shared.frontmostApplication
                return (app?.bundleIdentifier, app?.localizedName)
            },
            pasteInFront: {
                // Without Accessibility access macOS drops the keystroke: ask, and leave it copied.
                guard VolumeKeyTap.isTrusted else { return VolumeKeyTap.requestTrust() }
                PasteKeystroke.paste()
            })
    }

    init(
        pasteboard: NSPasteboard, defaults: UserDefaults, storeURL: URL, imagesURL: URL,
        frontmostApp: @escaping () -> (id: String?, name: String?),
        pasteInFront: @escaping @MainActor () -> Void = {}
    ) {
        self.pasteboard = pasteboard
        self.defaults = defaults
        self.storeURL = storeURL
        self.imagesURL = imagesURL
        self.frontmostApp = frontmostApp
        self.pasteInFront = pasteInFront
        isRecording = defaults.bool(forKey: Self.recordingKey)
        pastesAfterPicking = defaults.bool(forKey: Self.pastesKey)
        pastesAsPlainText = defaults.bool(forKey: Self.plainTextKey)
        cleansLinks = defaults.bool(forKey: Self.cleansLinksKey)
        ignoredApps = defaults.stringArray(forKey: Self.ignoredAppsKey) ?? []
    }

    public var view: some View { ClipboardView(clipboard: self) }

    /// The second row's search field, once there is a history to search.
    public var headerActions: some View { ClipboardSearch(clipboard: self) }

    /// Whether the tab shows the history, rather than asking to turn it on or to be allowed.
    var showsHistory: Bool { isRecording && access != .asks && access != .denied }

    /// Whether the change count is being checked.
    var isPolling: Bool { poll != nil }

    /// Starts keeping a history. Before macOS lets Topdeck read the clipboard, this read makes it
    /// ask once and list Topdeck in System Settings, where the user can always allow it.
    public func startRecording() {
        isRecording = true
        refreshAccess()
        if access == .notDetermined || access == .allowed {
            capture()
            refreshAccess()
        }
        update()
    }

    public func stopRecording() {
        isRecording = false
        update()
    }

    /// Re-reads access, which the user changes in System Settings.
    public func refreshAccess() {
        let was = access
        access = Self.access(of: pasteboard)
        if access != was { update() }
    }

    static func access(of pasteboard: NSPasteboard) -> ClipboardAccess {
        guard #available(macOS 15.4, *) else { return .allowed }
        switch pasteboard.accessBehavior {
        case .alwaysAllow: return .allowed
        case .alwaysDeny: return .denied
        case .ask: return .asks
        default: return .notDetermined
        }
    }

    /// Skips copies made in the app with this bundle ID from now on.
    public func ignoreApp(_ bundleID: String) {
        guard !ignoredApps.contains(bundleID) else { return }
        ignoredApps.append(bundleID)
    }

    public func stopIgnoringApp(_ bundleID: String) {
        ignoredApps.removeAll { $0 == bundleID }
    }

    var rules: ClipboardRules { ClipboardRules(ignoredApps: Set(ignoredApps)) }

    // MARK: History

    /// Items whose text, file names, or source app contain `query`, favorites first.
    public func search(_ query: String) -> [ClipItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let found =
            query.isEmpty
            ? items
            : items.filter {
                $0.text.localizedCaseInsensitiveContains(query)
                    || $0.source?.localizedCaseInsensitiveContains(query) == true
            }
        return found.filter(\.favorite) + found.filter { !$0.favorite }
    }

    /// Puts an item back on the clipboard, at the top of the history, and closes the notch. Then it
    /// pastes into the app in front if `paste`. Both choices default to the user's settings.
    public func pick(_ item: ClipItem, plainText: Bool? = nil, paste: Bool? = nil) {
        pasteboard.clearContents()
        switch item.kind {
        case .text, .link:
            pasteboard.setString(item.text, forType: .string)
            if !(plainText ?? pastesAsPlainText) {
                for (type, data) in item.rich ?? [:] { pasteboard.setData(data, forType: .init(type)) }
            }
        case .files:
            pasteboard.writeObjects(item.paths.map { URL(filePath: $0) as NSURL })
        case .image:
            if let image = image(for: item) { pasteboard.writeObjects([image]) }
        }
        lastChange = pasteboard.changeCount  // our own copy isn't news
        var used = item
        used.copied = .now
        items.removeAll { $0.id == item.id }
        items.insert(used, at: 0)
        save()
        onPicked?()
        if paste ?? pastesAfterPicking {
            pasteInFront()
        } else {
            onActivity?(
                Activity(feature: .clipboard, symbol: "doc.on.clipboard.fill", title: "Copied", duration: .seconds(2)))
        }
    }

    public func toggleFavorite(_ item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].favorite.toggle()
        save()
    }

    public func remove(_ item: ClipItem) { remove([item.id]) }

    /// Deletes the items picked in select mode, favorites too, and their images.
    public func remove(_ ids: Set<ClipItem.ID>) {
        for item in items where ids.contains(item.id) { forgetImage(of: item) }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    /// Clears the history; favorites stay.
    public func clear() {
        for item in items where !item.favorite { forgetImage(of: item) }
        items.removeAll { !$0.favorite }
        save()
    }

    /// The image an image item holds, from its file.
    public func image(for item: ClipItem) -> NSImage? {
        item.kind == .image ? NSImage(contentsOf: imageFile(item.id)) : nil
    }

    /// A small copy of an image item for the list, made once from its file rather than on every draw.
    public func thumbnail(for item: ClipItem) -> NSImage? {
        guard item.kind == .image else { return nil }
        let key = item.id.uuidString as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        guard let source = CGImageSourceCreateWithURL(imageFile(item.id) as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let thumbnail = NSImage(cgImage: image, size: .zero)
        thumbnails.setObject(thumbnail, forKey: key)
        return thumbnail
    }

    // MARK: Watching the clipboard

    /// Loads the history while the feature runs, and checks the clipboard only while it records
    /// and may read it; stopped, it lets go of everything.
    private func update() {
        if phase == .stopped {
            stopPolling()
            items = []
            thumbnails.removeAllObjects()
            return
        }
        if items.isEmpty { load() }
        if isRecording, access == .allowed {
            startPolling()
        } else {
            stopPolling()
        }
    }

    private func startPolling() {
        guard poll == nil else { return }
        lastChange = pasteboard.changeCount  // what's there already was copied before recording
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Leeway lets macOS fold the check into other wakeups (Apple's energy guidance).
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.resume()
        poll = timer
    }

    private func stopPolling() {
        poll?.cancel()
        poll = nil
    }

    /// One tick: a counter read, and the clipboard's contents only when that changed.
    func check() {
        let count = pasteboard.changeCount
        guard count != lastChange else { return }
        lastChange = count
        capture()
    }

    /// Adds what's on the clipboard now to the top of the history, unless it's private.
    func capture() {
        lastChange = pasteboard.changeCount
        let app = frontmostApp()
        // Every type on the pasteboard, not just the first item's: a mark on any of them counts.
        guard let types = pasteboard.types?.map(\.rawValue), !types.isEmpty else { return }
        let source = pasteboard.string(forType: .init(ClipboardRules.sourceType))
        guard !rules.ignores(types: types, apps: [app.id, source]), var item = read(types) else { return }
        item.source = app.name
        if item.kind == .link, cleansLinks {
            let cleaned = LinkCleaner.clean(item.text)
            if cleaned != item.text {
                item.text = cleaned
                item.rich = nil  // it would paste the old link back
            }
        }
        if let same = items.first(where: { $0.kind == item.kind && $0.text == item.text && $0.kind != .image }) {
            item.id = same.id  // copied again: it moves to the top
            item.favorite = same.favorite
            items.removeAll { $0.id == same.id }
        }
        items.insert(item, at: 0)
        trim()
        save()
    }

    /// Files, then images, then text: a copied file also carries its name as text, and an image
    /// from a browser carries its link.
    private func read(_ types: [String]) -> ClipItem? {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        if let urls = files as? [URL], !urls.isEmpty {
            return ClipItem(kind: .files, text: urls.map(\.path).joined(separator: "\n"), copied: .now)
        }
        let isImage = [NSPasteboard.PasteboardType.png, .tiff].contains { types.contains($0.rawValue) }
        if isImage, let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
            data.count <= Self.largestImage, let bitmap = NSBitmapImageRep(data: data),
            let png = bitmap.representation(using: .png, properties: [:])
        {
            let item = ClipItem(kind: .image, text: "Image \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)", copied: .now)
            do {
                try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
                try png.write(to: imageFile(item.id), options: .atomic)
                return item
            } catch {
                Log.features.error("Couldn't keep a copied image: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        guard let text = pasteboard.string(forType: .string), text.utf8.count <= Self.largestText,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let link = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
        let isLink = link?.scheme.map { ["http", "https"].contains($0.lowercased()) } == true && link?.host() != nil
        var rich: [String: Data] = [:]
        for type in Self.richTypes where types.contains(type.rawValue) {
            if let data = pasteboard.data(forType: type), data.count <= Self.largestRich { rich[type.rawValue] = data }
        }
        return ClipItem(kind: isLink ? .link : .text, text: text, rich: rich.isEmpty ? nil : rich, copied: .now)
    }

    /// Keeps the history to `capacity`, dropping the oldest items that aren't favorites.
    private func trim() {
        while items.count > Self.capacity, let oldest = items.lastIndex(where: { !$0.favorite }) {
            forgetImage(of: items.remove(at: oldest))
        }
    }

    private func imageFile(_ id: ClipItem.ID) -> URL { imagesURL.appending(path: "\(id.uuidString).png") }

    private func forgetImage(of item: ClipItem) {
        if item.kind == .image { try? FileManager.default.removeItem(at: imageFile(item.id)) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        items = (try? JSONDecoder().decode([ClipItem].self, from: data)) ?? []
    }

    private func save() {
        do {
            try JSONEncoder().encode(items).write(to: storeURL, options: .atomic)
        } catch {
            Log.features.error("Couldn't save the clipboard history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
