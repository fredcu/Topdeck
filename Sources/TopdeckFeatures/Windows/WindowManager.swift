// SPDX-License-Identifier: MIT
import AppKit
import ApplicationServices
import KeyboardShortcuts
import Observation

/// Moves and resizes other apps' windows: keyboard shortcuts for halves, thirds, quarters, almost
/// maximize and the next display, dragging a window to a screen edge, and saved layouts. It has no
/// notch tab; Settings has its page. Accessibility access, which moving other apps' windows needs, is
/// asked for only when it's turned on.
@MainActor
@Observable
public final class WindowManager {
    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Key.enabled)
            update()
        }
    }

    /// Dragging a window to a screen's edge or corner snaps it there.
    public var snapsOnDrag: Bool {
        didSet {
            defaults.set(snapsOnDrag, forKey: Key.snapsOnDrag)
            update()
        }
    }

    /// Points between windows, and between windows and the screen's edges.
    public var gap: Double {
        didSet { defaults.set(gap, forKey: Key.gap) }
    }

    public private(set) var layouts: [WindowLayout] {
        didSet { defaults.set(WindowLayout.encode(layouts), forKey: Key.layouts) }
    }

    /// Whether macOS lets Topdeck move other apps' windows.
    public private(set) var isTrusted = AXIsProcessTrusted()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var dragMonitor: Any?
    @ObservationIgnored private var drag: Drag?
    @ObservationIgnored private lazy var footprint = SnapFootprint()
    @ObservationIgnored private var trustObserver: (any NSObjectProtocol)?

    /// A window being dragged, from the mouse going down on it.
    private struct Drag {
        let window: AccessibilityWindow
        let start: CGRect
        var isMoving = false
        var action: WindowAction?
        var screen: NSScreen?
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.enabled)
        snapsOnDrag = defaults.object(forKey: Key.snapsOnDrag) as? Bool ?? true
        gap = defaults.double(forKey: Key.gap)
        layouts = WindowLayout.decode(defaults.data(forKey: Key.layouts))
    }

    /// Starts listening, if it's on, once the app has launched.
    public func activate() {
        update()
    }

    /// Asks macOS to show its Accessibility prompt, which leads to System Settings.
    public func requestAccess() {
        // kAXTrustedCheckOptionPrompt's value; the global itself isn't concurrency-safe in Swift 6.
        isTrusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public func refreshAccess() {
        isTrusted = AXIsProcessTrusted()
    }

    private func update() {
        if isEnabled, !isRunning {
            isRunning = true
            if !AXIsProcessTrusted() { requestAccess() }
            observeTrust()
            for action in WindowAction.allCases {
                KeyboardShortcuts.onKeyDown(for: .window(action)) { [weak self] in self?.perform(action) }
            }
            layouts.forEach(listen)
        } else if !isEnabled, isRunning {
            isRunning = false
            WindowAction.allCases.forEach { KeyboardShortcuts.removeHandler(for: .window($0)) }
            layouts.forEach { KeyboardShortcuts.removeHandler(for: .layout($0.id)) }
        }
        let watchesDrags = isEnabled && snapsOnDrag
        if watchesDrags, dragMonitor == nil {
            dragMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                MainActor.assumeIsolated { self?.handleDrag(event) }
            }
        } else if !watchesDrags, let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
            self.dragMonitor = nil
            drag = nil
            footprint.hide()
        }
    }

    /// Access arrives while running; macOS posts this when it changes.
    private func observeTrust() {
        guard trustObserver == nil else { return }
        trustObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))  // trust updates just after the notification
                self?.isTrusted = AXIsProcessTrusted()
            }
        }
    }

    // MARK: Actions

    /// Moves the focused window.
    public func perform(_ action: WindowAction) {
        guard AXIsProcessTrusted() else { return requestAccess() }
        guard let window = AccessibilityWindow.focused() else { return NSSound.beep() }
        move(window, action)
    }

    /// Moves `window` by `action` on `screen`, or the screen it's on now.
    private func move(_ window: AccessibilityWindow, _ action: WindowAction, on screen: NSScreen? = nil) {
        let screens = NSScreen.screens
        guard let primary = screens.first, let current = window.frame else { return }
        let height = primary.frame.height
        let frame = WindowFrames.flipped(current, primaryHeight: height)
        guard let index = WindowFrames.screen(for: frame, in: screens.map(\.frame)) else { return }
        let target: CGRect?
        if action == .nextDisplay {
            guard let next = WindowFrames.nextScreen(after: index, in: screens.map(\.frame)) else { return }
            target = WindowFrames.moved(
                frame, from: screens[index].visibleFrame, to: screens[next].visibleFrame, gap: gap)
        } else if let screen {
            target = WindowFrames.frame(for: action, window: nil, in: screen.visibleFrame, gap: gap)
        } else {
            target = WindowFrames.frame(for: action, window: frame, in: screens[index].visibleFrame, gap: gap)
        }
        guard let target else { return }
        window.setFrame(WindowFrames.flipped(target, primaryHeight: height))
    }

    // MARK: Drag to snap

    private func handleDrag(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            guard let height = NSScreen.screens.first?.frame.height else { return }
            let point = NSEvent.mouseLocation
            let window = AccessibilityWindow.window(at: CGPoint(x: point.x, y: height - point.y))
            drag = window.flatMap { window in window.frame.map { Drag(window: window, start: $0) } }
        case .leftMouseDragged:
            guard var drag else { return }
            if !drag.isMoving {
                // A window that moves without changing size is being dragged, not resized.
                guard let frame = drag.window.frame, frame.origin != drag.start.origin, frame.size == drag.start.size
                else { return }
                drag.isMoving = true
            }
            let point = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { Self.contains($0.frame, point) }
            let prior = drag.action
            drag.action = screen.flatMap { SnapAreas.action(at: point, in: $0.frame, prior: prior) }
            drag.screen = screen
            if let action = drag.action, let screen,
                let target = WindowFrames.frame(for: action, window: nil, in: screen.visibleFrame, gap: gap)
            {
                footprint.show(target)
            } else {
                footprint.hide()
            }
            self.drag = drag
        case .leftMouseUp:
            footprint.hide()
            if let drag, drag.isMoving, let action = drag.action, let screen = drag.screen {
                move(drag.window, action, on: screen)
            }
            drag = nil
        default: break
        }
    }

    /// Whether `point` is on `frame`, its top and right edges included: the pointer stops there.
    private static func contains(_ frame: CGRect, _ point: CGPoint) -> Bool {
        point.x >= frame.minX && point.x <= frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
    }

    // MARK: Layouts

    /// Saves where every open window is now as a new layout.
    public func saveLayout(named name: String) {
        let layout = WindowLayout(name: name, placements: placements())
        layouts.append(layout)
        if isRunning { listen(layout) }
    }

    /// Saves where every open window is now under an existing layout.
    public func updateLayout(_ layout: WindowLayout) {
        guard let index = layouts.firstIndex(where: { $0.id == layout.id }) else { return }
        layouts[index].placements = placements()
    }

    public func rename(_ layout: WindowLayout, to name: String) {
        guard let index = layouts.firstIndex(where: { $0.id == layout.id }) else { return }
        layouts[index].name = name
    }

    public func delete(_ layout: WindowLayout) {
        layouts.removeAll { $0.id == layout.id }
        KeyboardShortcuts.removeHandler(for: .layout(layout.id))
        KeyboardShortcuts.reset(.layout(layout.id))
    }

    /// Puts each open window of the layout's apps back where the layout has it. Windows on a display
    /// that isn't connected go to the main display.
    public func apply(_ layout: WindowLayout) {
        guard AXIsProcessTrusted() else { return requestAccess() }
        guard let height = NSScreen.screens.first?.frame.height else { return }
        let open = openWindows()
        let windows = open.map { WindowLayout.Window(app: $0.app, title: $0.window.title) }
        for (index, placement) in layout.assignments(for: windows) {
            let screen = NSScreen.screens.first { $0.windowDisplayUUID == placement.display } ?? NSScreen.main
            guard let screen else { continue }
            let frame = WindowLayout.frame(placement.frame, in: screen.visibleFrame)
            open[index].window.setFrame(WindowFrames.flipped(frame, primaryHeight: height))
        }
    }

    /// The layout's own shortcut applies it.
    private func listen(_ layout: WindowLayout) {
        let id = layout.id
        KeyboardShortcuts.onKeyDown(for: .layout(id)) { [weak self] in
            guard let self, let layout = layouts.first(where: { $0.id == id }) else { return }
            apply(layout)
        }
    }

    private func placements() -> [WindowLayout.Placement] {
        let screens = NSScreen.screens
        guard let height = screens.first?.frame.height else { return [] }
        return openWindows().compactMap { app, window in
            guard let current = window.frame else { return nil }
            let frame = WindowFrames.flipped(current, primaryHeight: height)
            guard let index = WindowFrames.screen(for: frame, in: screens.map(\.frame)) else { return nil }
            let screen = screens[index]
            return WindowLayout.Placement(
                app: app, title: window.title, display: screen.windowDisplayUUID,
                frame: WindowLayout.unit(frame, in: screen.visibleFrame))
        }
    }

    /// The windows of every app in the Dock that isn't hidden, Topdeck aside.
    private func openWindows() -> [(app: String, window: AccessibilityWindow)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isHidden && $0 != NSRunningApplication.current }
            .flatMap { app -> [(app: String, window: AccessibilityWindow)] in
                guard let id = app.bundleIdentifier else { return [] }
                return AccessibilityWindow.windows(of: app.processIdentifier).map { (app: id, window: $0) }
            }
    }

    private enum Key {
        static let enabled = "windowsEnabled"
        static let snapsOnDrag = "windowsSnapOnDrag"
        static let gap = "windowsGap"
        static let layouts = "windowLayouts"
    }
}

extension KeyboardShortcuts.Name {
    /// Each action's shortcut. They start as Control-Option with the arrows for halves, U, I, J and K
    /// for the corners, D, F and G for thirds, E and T for two thirds, Return to maximize, and
    /// Command-Right Arrow for the next display. Almost Maximize starts without one.
    static func window(_ action: WindowAction) -> Self {
        let name = "window" + action.rawValue.prefix(1).uppercased() + action.rawValue.dropFirst()
        return Self(name, initial: initialShortcut(for: action))
    }

    private static func initialShortcut(for action: WindowAction) -> KeyboardShortcuts.Shortcut? {
        let key: KeyboardShortcuts.Key
        switch action {
        case .leftHalf: key = .leftArrow
        case .rightHalf: key = .rightArrow
        case .topHalf: key = .upArrow
        case .bottomHalf: key = .downArrow
        case .topLeft: key = .u
        case .topRight: key = .i
        case .bottomLeft: key = .j
        case .bottomRight: key = .k
        case .firstThird: key = .d
        case .centerThird: key = .f
        case .lastThird: key = .g
        case .firstTwoThirds: key = .e
        case .lastTwoThirds: key = .t
        case .maximize: key = .return
        case .almostMaximize: return nil
        case .nextDisplay: return .init(.rightArrow, modifiers: [.control, .option, .command])
        }
        return .init(key, modifiers: [.control, .option])
    }

    /// A saved layout's shortcut. None to start with.
    static func layout(_ id: UUID) -> Self {
        Self("windowLayout-\(id.uuidString)")
    }
}
