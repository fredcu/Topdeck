// SPDX-License-Identifier: MIT
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// The pictures on the Shelf's tiles. Quick Look makes each one off the main thread; made pictures stay
/// in memory (at most 200) so scrolling back is instant.
@MainActor
final class ShelfThumbnails {
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    /// A CGImage handed back from Quick Look's queue. Core Graphics images don't change once made.
    private struct Made: @unchecked Sendable { let image: CGImage? }

    private func key(_ url: URL, _ size: CGSize) -> NSString {
        "\(url.path)|\(Int(size.width))x\(Int(size.height))" as NSString
    }

    /// A thumbnail made already, so a tile that scrolls back into view doesn't flash its kind first.
    func cached(for url: URL, size: CGSize) -> NSImage? { cache.object(forKey: key(url, size)) }

    /// The file's thumbnail, or nil when Quick Look has none and the tile shows its kind instead.
    func image(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        let key = key(url, size)
        if let cached = cache.object(forKey: key) { return cached }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        let made = await withCheckedContinuation { (continuation: CheckedContinuation<Made, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: Made(image: representation?.cgImage))
            }
        }
        guard let cgImage = made.image else { return nil }
        let image = NSImage(cgImage: cgImage, size: size)
        cache.setObject(image, forKey: key)
        return image
    }

    func removeAll() { cache.removeAllObjects() }
}

/// A pop-up of the apps that can open files, shown where the pointer is.
@MainActor
final class OpenWithMenu: NSObject {
    private let urls: [URL]

    private init(urls: [URL]) { self.urls = urls }

    /// Lists the apps that open the first file, the default first; with none, opens the files as usual.
    static func show(for urls: [URL]) {
        guard let first = urls.first else { return }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: first)
        guard !apps.isEmpty else {
            for url in urls { NSWorkspace.shared.open(url) }
            return
        }
        let chooser = OpenWithMenu(urls: urls)
        let menu = NSMenu()
        for app in apps.prefix(15) {
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            let item = NSMenuItem(title: name, action: #selector(open(_:)), keyEquivalent: "")
            item.target = chooser
            item.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
