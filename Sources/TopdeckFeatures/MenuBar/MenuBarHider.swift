// SPDX-License-Identifier: MIT
// Adapted from OmniMac (https://github.com/BySergiMM/OmniMac) at 6a56641: Features/MenuBar/MenuBarFeature.swift.
// Copyright (c) 2026 Sergi (BySergiMM). MIT License; changed for Topdeck: a Settings page and a timed
// collapse in place of the shortcut, with comments translated from Spanish. See THIRD_PARTY_NOTICES.md.
import Foundation
import Observation

/// The two status items the hider owns, as the hider drives them.
@MainActor
protocol MenuBarSurface: AnyObject {
    var onClick: (() -> Void)? { get set }
    func install()
    func remove()
    func render(collapsed: Bool)
}

/// Hides menu bar icons behind Topdeck's item. The user Command-drags icons to the left of the divider;
/// a click on the arrow shows them, and they hide again after a delay. It needs no private API and no
/// permission: an item that grows wide pushes everything on its left out of the bar. It has no notch tab;
/// Settings has its page. Turning it off, or quitting, removes both items and every icon is back.
@MainActor
@Observable
public final class MenuBarHider {
    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Key.enabled)
            isEnabled ? start() : stop()
        }
    }

    /// Seconds an opened bar stays open.
    public var collapseDelay: Double {
        didSet {
            defaults.set(collapseDelay, forKey: Key.delay)
            scheduleCollapse()
        }
    }

    /// The autosave name of Topdeck's own menu bar item.
    public static let statusItemName = MenuBarLayout.ownName

    /// Called once Topdeck's own item has a stored position, so it can be made again to take it.
    @ObservationIgnored public var onPlaced: (() -> Void)?
    @ObservationIgnored public private(set) var isCollapsed = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let surface: any MenuBarSurface
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var collapseTask: Task<Void, Never>?

    private enum Key {
        static let enabled = "menuBar.enabled"
        static let delay = "menuBar.collapseDelay"
    }

    public convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, surface: StatusBarSurface())
    }

    init(defaults: UserDefaults, surface: any MenuBarSurface) {
        self.defaults = defaults
        self.surface = surface
        isEnabled = defaults.bool(forKey: Key.enabled)
        collapseDelay = defaults.object(forKey: Key.delay) as? Double ?? MenuBarLayout.defaultDelay
        surface.onClick = { [weak self] in self?.toggle() }
    }

    /// Starts, if it's on, once the app has launched and before it makes its own menu bar item.
    public func activate() {
        if isEnabled { start() }
    }

    /// Removes both items, which brings back every hidden icon.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        collapseTask?.cancel()
        collapseTask = nil
        removeItems()
    }

    public func toggle() {
        guard isRunning else { return }
        isCollapsed ? expand() : collapse()
    }

    private func start() {
        guard !isRunning else { return }
        isRunning = true
        install()
        // It opens first, so the divider shows where it sits before anything is hidden behind it.
        expand()
    }

    private func install() {
        MenuBarLayout.place(in: defaults)
        onPlaced?()
        surface.install()
    }

    private func removeItems() {
        let names = MenuBarLayout.defaults.prefix(2).map(\.name)
        let positions = MenuBarLayout.saved(names, in: defaults)
        surface.remove()
        MenuBarLayout.restore(positions, in: defaults)
    }

    private func expand() {
        isCollapsed = false
        surface.render(collapsed: false)
        scheduleCollapse()
    }

    private func collapse() {
        // Dragging the divider can leave our own item behind it, which would hide the way back.
        if MenuBarLayout.isSwallowed(in: defaults) {
            removeItems()
            install()
        }
        isCollapsed = true
        collapseTask?.cancel()
        collapseTask = nil
        surface.render(collapsed: true)
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
        guard isRunning, !isCollapsed else { return }
        collapseTask = Task { [weak self, delay = collapseDelay] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.collapse()
        }
    }
}
