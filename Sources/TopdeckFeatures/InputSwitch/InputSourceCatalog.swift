// SPDX-License-Identifier: MIT
// Adapted from MacTools (https://github.com/mactools-app/MacTools) at 9197035: Plugins/AutoInput/Sources/
// AutoInputSourceCatalog.swift and AutoInputApplicationMonitor.swift. Copyright (c) 2026 ggbond268. Apache
// License 2.0; changed for Topdeck: the sources' languages, and the CJKV focus nudge, after macism (MIT,
// Copyright (c) 2023 laishulu). See THIRD_PARTY_NOTICES.md.
import AppKit
import Carbon.HIToolbox

extension InputSwitcher {
    /// The switcher on this Mac's input sources and apps, with its settings in `defaults`.
    public convenience init(defaults: UserDefaults = .standard) {
        self.init(
            store: InputSwitchStore(defaults: defaults), inputSources: InputSourceCatalog(),
            apps: WorkspaceAppMonitor(), ownBundleID: Bundle.main.bundleIdentifier)
    }
}

enum InputSourceError: Error {
    case unavailable
    case refused(OSStatus)
}

/// The input sources from Text Input Sources Services, watched through its distributed notifications.
@MainActor
final class InputSourceCatalog: InputSourceControlling {
    var onChange: (() -> Void)?
    private(set) var sources: [InputSource] = []
    private var references: [String: TISInputSource] = [:]
    private var observers: [NSObjectProtocol] = []
    private let nudge = InputFocusNudge()

    init() {
        refresh()
    }

    var currentID: String? {
        Self.string(TISCopyCurrentKeyboardInputSource().takeRetainedValue(), kTISPropertyInputSourceID)
    }

    func start() {
        guard observers.isEmpty else { return }
        refresh()
        let center = DistributedNotificationCenter.default()
        let names: [String] = [
            kTISNotifySelectedKeyboardInputSourceChanged as String,
            kTISNotifyEnabledKeyboardInputSourcesChanged as String,
        ]
        observers = names.map { name in
            center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                // A hop rather than assuming isolation: system notifications can arrive on the main
                // thread without the main actor's executor in place.
                Task { @MainActor in
                    self?.refresh()
                    self?.onChange?()
                }
            }
        }
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        observers.forEach(center.removeObserver)
        observers = []
        nudge.cancel()
    }

    /// Keyboard sources that are on and can be selected: layouts and input modes, not the input methods
    /// that hold the modes, and not palettes.
    func refresh() {
        guard let list = TISCreateInputSourceList(nil, false).takeRetainedValue() as? [TISInputSource] else {
            references = [:]
            sources = []
            return
        }
        var references: [String: TISInputSource] = [:]
        var sources: [InputSource] = []
        for source in list {
            guard Self.bool(source, kTISPropertyInputSourceIsEnabled) == true,
                Self.bool(source, kTISPropertyInputSourceIsSelectCapable) == true,
                Self.string(source, kTISPropertyInputSourceCategory) == kTISCategoryKeyboardInputSource as String,
                let id = Self.string(source, kTISPropertyInputSourceID)
            else { continue }
            references[id] = source
            let languages = Self.property(source, kTISPropertyInputSourceLanguages) as? [String] ?? []
            sources.append(
                InputSource(id: id, name: Self.string(source, kTISPropertyLocalizedName) ?? id, languages: languages))
        }
        self.references = references
        self.sources = sources.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func select(_ id: String) throws {
        if references[id] == nil { refresh() }
        guard let reference = references[id], let source = sources.first(where: { $0.id == id }) else {
            throw InputSourceError.unavailable
        }
        let status = TISSelectInputSource(reference)
        guard status == noErr else { throw InputSourceError.refused(status) }
        // The system now reports the CJKV source as selected, but the app in front can keep typing with
        // the old one until its key window changes. Taking the keyboard for a moment and handing it back
        // makes the app pick the new source up.
        if source.isCJKV { nudge.run() }
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        property(source, key) as? String
    }

    private static func bool(_ source: TISInputSource, _ key: CFString) -> Bool? {
        property(source, key) as? Bool
    }
}

/// Moves keyboard focus away from the app in front and back, so it picks up an input source selected
/// from outside it. A one-point transparent panel that doesn't activate Topdeck takes the keyboard,
/// holds it briefly, and orders out, which hands the keyboard back as the notch does when it closes.
@MainActor
final class InputFocusNudge {
    /// How long the panel keeps the keyboard. macism measured 150 ms as the shortest that always works
    /// on macOS 26.
    static let hold = Duration.milliseconds(150)
    private var panel: NSPanel?
    private var release: Task<Void, Never>?

    func run() {
        guard let screen = NSScreen.main else { return }
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        let visible = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: visible.maxX - 1, y: visible.minY))
        panel.makeKeyAndOrderFront(nil)
        _ = panel.makeFirstResponder(panel.contentView)
        release?.cancel()
        release = Task { [weak self] in
            try? await Task.sleep(for: Self.hold)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    func cancel() {
        release?.cancel()
        release = nil
        panel?.orderOut(nil)
    }

    private static func makePanel() -> NSPanel {
        let panel = NudgePanel(
            contentRect: CGRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // A text view, so the keyboard lands in a text input client of Topdeck's for that moment.
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        text.drawsBackground = false
        text.isEditable = true
        text.setAccessibilityElement(false)
        panel.contentView = text
        return panel
    }
}

private final class NudgePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The app in front, from NSWorkspace's activation notifications.
@MainActor
final class WorkspaceAppMonitor: FrontmostAppMonitoring {
    var onActivate: ((InputSwitchApp) -> Void)?
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.center = center
    }

    var frontmost: InputSwitchApp? { NSWorkspace.shared.frontmostApplication.flatMap(Self.app) }

    func start() {
        guard observer == nil else { return }
        observer = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard
                let running = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let app = Self.app(running)
            else { return }
            Task { @MainActor in self?.onActivate?(app) }
        }
    }

    func stop() {
        guard let observer else { return }
        center.removeObserver(observer)
        self.observer = nil
    }

    private nonisolated static func app(_ running: NSRunningApplication) -> InputSwitchApp? {
        guard let bundleID = running.bundleIdentifier, !bundleID.isEmpty else { return nil }
        return InputSwitchApp(bundleID: bundleID, name: running.localizedName ?? bundleID)
    }
}
