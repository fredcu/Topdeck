// SPDX-License-Identifier: MIT
// Adapted from OmniMac's WindowSwitcher (https://github.com/BySergiMM/OmniMac), Copyright (c) 2026
// Sergi (BySergiMM), MIT License.
import AppKit
import ApplicationServices
import KeyboardShortcuts
import Observation

/// Option-Tab (or the shortcut you choose) shows every window, not only every app. While it is up,
/// Tab and the arrows move, typing filters, Escape cancels, and letting go of the modifier picks. It
/// has no notch tab; Settings has its page. Accessibility and Screen Recording are asked for when it
/// is turned on, and windows are captured only while the switcher is showing.
@MainActor
@Observable
public final class WindowSwitcher {
    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Key.enabled)
            update()
            if isEnabled, !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        }
    }

    public private(set) var isTrusted = AXIsProcessTrusted()
    public private(set) var canCapture = CGPreflightScreenCaptureAccess()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private let panel = SwitcherPanelController()
    @ObservationIgnored private var windows: [Int: AccessibilityWindow] = [:]
    @ObservationIgnored private var monitors: [Any] = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.enabled)
        panel.onClick = { [weak self] in self?.end(commit: true) }
        panel.onResign = { [weak self] in self?.end(commit: false) }
    }

    /// Starts listening, if it's on, once the app has launched.
    public func activate() {
        update()
    }

    public func requestAccess() {
        // kAXTrustedCheckOptionPrompt's value; the global itself isn't concurrency-safe in Swift 6.
        isTrusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public func requestCapture() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(.privacySettings("Privacy_ScreenCapture"))
    }

    public func refreshAccess() {
        isTrusted = AXIsProcessTrusted()
        canCapture = CGPreflightScreenCaptureAccess()
    }

    private func update() {
        if isEnabled, !isRunning {
            isRunning = true
            if !AXIsProcessTrusted() { requestAccess() }
            KeyboardShortcuts.onKeyDown(for: .windowSwitcher) { [weak self] in self?.shortcutPressed() }
        } else if !isEnabled, isRunning {
            isRunning = false
            KeyboardShortcuts.removeHandler(for: .windowSwitcher)
            end(commit: false)
        }
    }

    // MARK: Session

    /// The shortcut opens the switcher; pressed again while it is up, it moves on, like repeated Tab.
    private func shortcutPressed() {
        if panel.isVisible {
            panel.move(1)
        } else {
            begin()
        }
    }

    private func begin() {
        guard AXIsProcessTrusted() else { return requestAccess() }
        let onScreen = Self.onScreenWindows()
        let (entries, windows) = Self.enumerate()
        let ids = SwitcherList.windowIDs(for: entries, onScreen: onScreen)
        let ordered = SwitcherList.ordered(entries, windowIDs: ids, onScreen: onScreen)
        guard !ordered.isEmpty else { return }
        self.windows = windows
        let frontIsHidden = NSWorkspace.shared.frontmostApplication == NSRunningApplication.current
        panel.show(
            entries: ordered, windowIDs: ids, captures: CGPreflightScreenCaptureAccess(),
            initial: SwitcherSelection.initial(count: ordered.count, backward: false, frontIsHidden: frontIsHidden))
        watchKeys()
        // A tap of the shortcut: the modifier is already up, so go straight to the previous window.
        if let required = Self.heldModifiers, !NSEvent.modifierFlags.contains(required) { end(commit: true) }
    }

    private func end(commit: Bool) {
        guard panel.isVisible else { return }
        let picked = panel.selected
        panel.hide()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if commit, let picked, let window = windows[picked.id] { window.raise() }
        windows = [:]
    }

    /// The modifiers of the shortcut, which the switcher stays up for. None, when it has none.
    private static var heldModifiers: NSEvent.ModifierFlags? {
        guard let modifiers = KeyboardShortcuts.getShortcut(for: .windowSwitcher)?.modifiers else { return nil }
        let held = modifiers.intersection([.command, .option, .control, .shift])
        return held.isEmpty ? nil : held
    }

    /// Keys go to the switcher's panel, which is key without Topdeck being active. Letting go of the
    /// shortcut's modifier is seen by the panel, or by the global monitor when it isn't key yet.
    private func watchKeys() {
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            handle(event)
            return nil
        }
        let flags: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let required = Self.heldModifiers else { return }
                if !NSEvent.modifierFlags.contains(required) { self.end(commit: true) }
            }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            flags(event)
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags)
        monitors = [keys, local, global].compactMap { $0 }
    }

    private func handle(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case 48: panel.move(event.modifierFlags.contains(.shift) ? -1 : 1)  // Tab
        case 123: panel.move(-1)
        case 124: panel.move(1)
        case 125: panel.moveRow(1)
        case 126: panel.moveRow(-1)
        case 53: end(commit: false)  // Escape
        case 36, 76: end(commit: true)  // Return, Enter
        case 51: panel.deleteBackward()
        default:
            guard event.modifierFlags.isDisjoint(with: [.command, .control]),
                let typed = event.charactersIgnoringModifiers,
                typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
            else { return }
            panel.type(typed)
        }
    }

    // MARK: Windows

    /// Every standard window of every app in the Dock, Topdeck aside, minimized ones too.
    private static func enumerate() -> (entries: [SwitcherEntry], windows: [Int: AccessibilityWindow]) {
        var entries: [SwitcherEntry] = []
        var windows: [Int: AccessibilityWindow] = [:]
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app != NSRunningApplication.current {
            let name = app.localizedName ?? app.bundleIdentifier ?? "App"
            for window in AccessibilityWindow.windows(of: app.processIdentifier, includingMinimized: true) {
                let title = window.title
                entries.append(
                    SwitcherEntry(
                        id: entries.count, pid: app.processIdentifier, appName: name,
                        title: title.isEmpty ? name : title, isMinimized: window.isMinimized, bounds: window.frame))
                windows[entries.count - 1] = window
            }
        }
        return (entries, windows)
    }

    /// Windows in the normal layer on the current Space, front to back.
    private static func onScreenWindows() -> [OnScreenWindow] {
        let info =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return info.compactMap { entry in
            guard entry[kCGWindowLayer as String] as? Int == 0,
                let number = entry[kCGWindowNumber as String] as? Int,
                let pid = entry[kCGWindowOwnerPID as String] as? Int,
                let boundsInfo = entry[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsInfo)
            else { return nil }
            return OnScreenWindow(
                windowID: CGWindowID(number), pid: pid_t(pid),
                title: entry[kCGWindowName as String] as? String ?? "", bounds: bounds)
        }
    }

    private enum Key {
        static let enabled = "windowSwitcherEnabled"
    }
}

extension KeyboardShortcuts.Name {
    /// Option-Tab to start with.
    static let windowSwitcher = Self("windowSwitcher", initial: .init(.tab, modifiers: [.option]))
}
