// SPDX-License-Identifier: MIT
import AppKit

/// The menu bar fallback: always reachable, even when the notch is hidden or misbehaving. The menu
/// is rebuilt each time it opens, so it shows the running version and the updater's state. Its
/// items carry symbols, as the system's own menus do.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let updater: Updater
    private let openSettings: (SettingsSelection.Page?) -> Void

    init(updater: Updater, openSettings: @escaping (SettingsSelection.Page?) -> Void) {
        self.updater = updater
        self.openSettings = openSettings
        super.init()
        statusItem.button?.image = NSImage(
            systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Topdeck")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: "Topdeck \(Updater.version)"))
        menu.addItem(menuItem("Settings…", symbol: "gearshape", #selector(showSettings), key: ","))
        for item in updateItems() { menu.addItem(item) }
        menu.addItem(.separator())
        menu.addItem(menuItem("About Topdeck", symbol: "info.circle", #selector(showAbout)))
        menu.addItem(
            menuItem("What's New in \(Updater.shortVersion)", symbol: "sparkles", #selector(showReleaseNotes)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Topdeck", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)
    }

    private func updateItems() -> [NSMenuItem] {
        let symbol = "arrow.triangle.2.circlepath"
        guard updater.sourceDirectory != nil else {
            return [menuItem("Check for Updates…", symbol: symbol, #selector(checkForUpdates))]
        }
        switch updater.state {
        case .idle:
            return [menuItem("Update Topdeck", symbol: symbol, #selector(update))]
        case .updating:
            let item = menuItem("Updating Topdeck…", symbol: symbol, nil)
            item.isEnabled = false
            return [item]
        case .failed:
            return [
                menuItem("Update Failed: Show Log", symbol: "exclamationmark.triangle", #selector(showLog)),
                menuItem("Try Updating Again", symbol: symbol, #selector(update)),
            ]
        }
    }

    private func menuItem(_ title: String, symbol: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    @objc private func showSettings() { openSettings(nil) }
    @objc private func showAbout() { openSettings(.about) }
    @objc private func showReleaseNotes() { NSWorkspace.shared.open(Links.releaseNotes(Updater.shortVersion)) }
    @objc private func update() { updater.updateFromSource() }
    @objc private func showLog() { updater.showLog() }
    @objc private func checkForUpdates() { updater.checkForUpdates() }
}

enum Links {
    static let repository = URL(string: "https://github.com/fredcu/Topdeck")!
    static let releases = URL(string: "https://github.com/fredcu/Topdeck/releases")!
    static let contributing = URL(string: "https://github.com/fredcu/Topdeck/blob/main/CONTRIBUTING.md")!
    static let newIssue = URL(string: "https://github.com/fredcu/Topdeck/issues/new/choose")!
    static let privacy = URL(string: "https://github.com/fredcu/Topdeck/blob/main/PRIVACY.md")!
    /// Rendered on GitHub; the direct download also carries a copy in its Resources.
    static let acknowledgements = URL(
        string: "https://github.com/fredcu/Topdeck/blob/main/THIRD_PARTY_NOTICES.md")!

    /// A release's page, with its notes and download.
    static func releaseNotes(_ version: String) -> URL { releases.appending(path: "tag/v\(version)") }
}
