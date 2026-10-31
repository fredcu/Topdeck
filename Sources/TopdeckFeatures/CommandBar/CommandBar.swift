// SPDX-License-Identifier: MIT
// Adapted from OmniMac's CommandBarFeature (MIT), Copyright (c) 2026 Sergi (BySergiMM); see THIRD_PARTY_NOTICES.md.
import AppKit
import KeyboardShortcuts
import Observation
import SwiftUI
import TopdeckCore

/// A search panel opened from any app: type, and it fuzzy-matches installed apps and the actions
/// features offer; Return runs the top one. It has no notch tab; Settings has its page. It is off to
/// start with, because many people use Option-Space for another launcher.
///
/// Features add their actions to `actions` in `AppDelegate`; the bar imports none of them. Nothing
/// runs except on Return or a click. The list of apps is built when the bar opens and dropped when
/// it closes.
@MainActor
@Observable
public final class CommandBar {
    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Key.enabled)
            update()
        }
    }

    /// The actions on offer, asked for each time the bar opens so they follow what's turned on.
    @ObservationIgnored public var actions: () -> [CommandAction] = { [] }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let model = CommandBarModel()
    @ObservationIgnored private var window: CommandBarWindow?
    @ObservationIgnored private var isListening = false
    @ObservationIgnored private var isShown = false
    @ObservationIgnored private var topEdge: CGFloat = 0
    @ObservationIgnored private var indexing: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.enabled)
        model.onResize = { [weak self] _ in self?.resize() }
        model.onClose = { [weak self] in self?.hide() }
        model.onRun = { [weak self] action in self?.run(action) }
    }

    /// Starts listening for the shortcut, if it's on, once the app has launched.
    public func activate() { update() }

    public func stop() {
        hide()
        if isListening {
            isListening = false
            KeyboardShortcuts.removeHandler(for: .commandBar)
        }
    }

    private func update() {
        if isEnabled, !isListening {
            isListening = true
            KeyboardShortcuts.onKeyDown(for: .commandBar) { [weak self] in
                MainActor.assumeIsolated { self?.toggle() }
            }
        } else if !isEnabled {
            stop()
        }
    }

    private func toggle() {
        isShown ? hide() : show()
    }

    // MARK: Showing

    private func show() {
        model.search = CommandSearch()
        model.search.setItems(actions())
        let window = self.window ?? makeWindow()
        self.window = window
        topEdge = Self.topEdge()
        isShown = true
        resize()
        window.makeKeyAndOrderFront(nil)
        // Listing the folders takes a moment; the actions are there meanwhile.
        indexing?.cancel()
        indexing = Task { [weak self] in
            let apps = await Task.detached(priority: .userInitiated) { InstalledApps.list() }.value
            guard let self, isShown, !Task.isCancelled else { return }
            model.search.add(apps.map(Self.action(for:)))
        }
    }

    private func hide() {
        guard isShown else { return }
        isShown = false
        indexing?.cancel()
        indexing = nil
        window?.orderOut(nil)
        model.search = CommandSearch()  // the apps aren't kept while nobody searches
    }

    private func run(_ action: CommandAction) {
        hide()
        // Let the bar leave first, so a window action finds the window that was in front.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            action.run()
        }
    }

    private func makeWindow() -> CommandBarWindow {
        let window = CommandBarWindow()
        window.delegate = closer
        let host = NSHostingView(rootView: CommandBarView(model: model))
        host.sizingOptions = []
        window.contentView = host
        return window
    }

    /// Closes the bar when it loses the keyboard: a click elsewhere, or Command-Tab.
    @ObservationIgnored private lazy var closer = ResignCloser { [weak self] in self?.hide() }

    private final class ResignCloser: NSObject, NSWindowDelegate {
        let close: @MainActor () -> Void
        init(_ close: @escaping @MainActor () -> Void) { self.close = close }
        func windowDidResignKey(_ notification: Notification) {
            MainActor.assumeIsolated { close() }
        }
    }

    // MARK: Placement

    /// The top edge, a little above the middle of the display under the pointer, kept while the
    /// list grows so the search line doesn't move.
    private static func topEdge() -> CGFloat {
        let screen = screenUnderPointer()
        let full = CommandBarView.height(rows: CommandBarView.maxRows, hasQuery: false)
        return (screen?.visibleFrame.midY ?? 500) + full / 2 + 110
    }

    private static func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    }

    private func resize() {
        guard let window, isShown else { return }
        let search = model.search
        let height = CommandBarView.height(rows: search.results.count, hasQuery: !search.query.isEmpty)
        let midX = Self.screenUnderPointer()?.visibleFrame.midX ?? 0
        window.setFrame(
            NSRect(
                x: midX - CommandBarView.width / 2, y: topEdge - height, width: CommandBarView.width, height: height),
            display: true)
    }

    // MARK: Apps

    private static func action(for app: InstalledApps.App) -> CommandAction {
        CommandAction(
            id: CommandAction.appPrefix + app.path, title: app.name, area: "App", symbol: "app.fill",
            keywords: "\(app.fileName) open launch"
        ) {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                if error != nil { Log.features.error("Couldn't open \(app.name, privacy: .public)") }
            }
        }
    }

    private enum Key {
        static let enabled = "commandBarEnabled"
    }
}

/// The apps in the usual folders, by the name Finder shows: on a Mac set to another language,
/// System Settings is `System Settings.app` on disk but searched for by its translated name.
enum InstalledApps {
    struct App: Sendable {
        let name: String
        let fileName: String
        let path: String
    }

    static func list() -> [App] {
        let manager = FileManager.default
        let folders = [
            "/Applications", "/Applications/Utilities", "/System/Applications",
            "/System/Applications/Utilities", NSHomeDirectory() + "/Applications",
        ]
        var seen = Set<String>()
        var apps: [App] = []

        func add(_ path: String) {
            let fileName = String((path as NSString).lastPathComponent.dropLast(4))
            let shown = manager.displayName(atPath: path)
            let name = shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown
            guard seen.insert(name.isEmpty ? fileName : name).inserted else { return }
            apps.append(App(name: name.isEmpty ? fileName : name, fileName: fileName, path: path))
        }

        // Finder lives in CoreServices, a folder full of helpers nobody wants to open.
        add("/System/Library/CoreServices/Finder.app")
        for folder in folders {
            for name in (try? manager.contentsOfDirectory(atPath: folder)) ?? [] {
                let path = folder + "/" + name
                if name.hasSuffix(".app") {
                    add(path)
                } else if folder == "/Applications", !name.hasPrefix(".") {
                    // One level down: vendors put their apps in a folder of their own.
                    for inner in (try? manager.contentsOfDirectory(atPath: path)) ?? [] where inner.hasSuffix(".app") {
                        add(path + "/" + inner)
                    }
                }
            }
        }
        return apps
    }
}

extension KeyboardShortcuts.Name {
    /// Option-Space to start with.
    static let commandBar = Self("commandBar", initial: .init(.space, modifiers: [.option]))
}

extension WindowAction {
    /// Its shortcut as keys, such as "⌃⌥←", where one is set.
    @MainActor public var shortcutText: String? { KeyboardShortcuts.getShortcut(for: .window(self))?.description }
}
