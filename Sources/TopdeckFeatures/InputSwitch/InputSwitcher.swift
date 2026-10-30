// SPDX-License-Identifier: MIT
// Adapted from MacTools (https://github.com/mactools-app/MacTools) at 9197035: Plugins/AutoInput/Sources/
// AutoInputController.swift. Copyright (c) 2026 ggbond268. Apache License 2.0; changed for Topdeck: switching
// and remembering only, without the input source HUD or focus tracking. See THIRD_PARTY_NOTICES.md.
import Foundation
import Observation
import TopdeckCore

/// The system's keyboard input sources: the ones turned on, the current one, and selecting one.
@MainActor
protocol InputSourceControlling: AnyObject {
    /// Called when the current source or the list of sources changes.
    var onChange: (() -> Void)? { get set }
    var sources: [InputSource] { get }
    var currentID: String? { get }
    func start()
    func stop()
    func refresh()
    /// Throws when the source is gone or the system refuses it.
    func select(_ id: String) throws
}

/// Tells when another app comes to the front.
@MainActor
protocol FrontmostAppMonitoring: AnyObject {
    var onActivate: ((InputSwitchApp) -> Void)? { get set }
    var frontmost: InputSwitchApp? { get }
    func start()
    func stop()
}

/// Switches the keyboard input source as apps come to the front: to the source the user set for the
/// app, or to the one it was last left with. Driven by the system's notifications, with no polling.
@MainActor
@Observable
public final class InputSwitcher {
    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            store.isEnabled = isEnabled
            isEnabled ? start() : stop()
        }
    }
    /// Apps without a source of their own get the one they were last left with.
    public var remembers: Bool {
        didSet { store.remembers = remembers }
    }
    public private(set) var rules: InputSwitchRules {
        didSet { store.rules = rules }
    }
    public private(set) var sources: [InputSource] = []

    @ObservationIgnored private let store: InputSwitchStore
    @ObservationIgnored private let inputSources: any InputSourceControlling
    @ObservationIgnored private let apps: any FrontmostAppMonitoring
    /// Topdeck's own windows, Settings and the notch's text fields, keep whatever source is on.
    @ObservationIgnored private let ownBundleID: String?
    /// The app the current source belongs to: a change of source while it's in front is its choice.
    @ObservationIgnored private var owner: InputSwitchApp?
    @ObservationIgnored private var isRunning = false

    init(
        store: InputSwitchStore, inputSources: any InputSourceControlling, apps: any FrontmostAppMonitoring,
        ownBundleID: String?
    ) {
        self.store = store
        self.inputSources = inputSources
        self.apps = apps
        self.ownBundleID = ownBundleID
        isEnabled = store.isEnabled
        remembers = store.remembers
        rules = store.rules
    }

    /// Picks up the stored settings, and starts listening when switching is on.
    public func resume() {
        if isEnabled { start() }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        apps.stop()
        inputSources.stop()
        apps.onActivate = nil
        inputSources.onChange = nil
        owner = nil
    }

    /// Always `sourceID` in `app`; nil goes back to remembering.
    public func fix(_ sourceID: String?, for app: InputSwitchApp) {
        rules.fix(sourceID, for: app)
        // Setting the app in front applies at once, as switching to it would.
        if isRunning, owner?.bundleID == app.bundleID { apply(to: app) }
    }

    public func forgetRemembered() {
        rules.forgetRemembered()
    }

    /// The source list, fresh, for Settings.
    public func refreshSources() {
        inputSources.refresh()
        sources = inputSources.sources
    }

    public func source(_ id: String) -> InputSource? { sources.first { $0.id == id } }

    public var currentSourceID: String? { inputSources.currentID }

    private func start() {
        guard !isRunning else { return }
        isRunning = true
        inputSources.onChange = { [weak self] in self?.sourcesDidChange() }
        apps.onActivate = { [weak self] in self?.appDidActivate($0) }
        inputSources.start()
        apps.start()
        sources = inputSources.sources
        // The app in front now owns the current source; it switches when it next comes back.
        owner = apps.frontmost.flatMap { $0.bundleID == ownBundleID ? nil : $0 }
    }

    func appDidActivate(_ app: InputSwitchApp) {
        guard isRunning else { return }
        guard app.bundleID != ownBundleID else {
            // Typing in Topdeck belongs to no app: the next app gets its own source back.
            rememberCurrent()
            owner = nil
            return
        }
        if owner?.bundleID != app.bundleID { rememberCurrent() }
        owner = app
        apply(to: app)
    }

    func sourcesDidChange() {
        guard isRunning else { return }
        sources = inputSources.sources
        rememberCurrent()
    }

    private func apply(to app: InputSwitchApp) {
        let available = Set(sources.map(\.id))
        guard let choice = rules.choice(for: app.bundleID, available: available, remembers: remembers),
            choice.sourceID != inputSources.currentID
        else { return }
        do {
            try inputSources.select(choice.sourceID)
        } catch {
            Log.features.error("Couldn't switch input source: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The owner was left with the current source.
    private func rememberCurrent() {
        guard remembers, let owner, let current = inputSources.currentID,
            sources.contains(where: { $0.id == current })
        else { return }
        guard rules.entries[owner.bundleID]?.remembered != current else { return }
        rules.remember(current, for: owner)
    }
}
