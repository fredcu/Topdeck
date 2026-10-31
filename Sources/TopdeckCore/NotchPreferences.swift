// SPDX-License-Identifier: MIT
// CGSize through Foundation alone makes Swift 6.3 serialize the size constants below with Double
// fields, and Release builds of TopdeckSurface then crash the optimizer.
import CoreGraphics
import Foundation
import Observation

/// How the notch opens and closes. Hover feedback and live activities keep their own subtle
/// motion, and Reduce Motion overrides every style.
public enum NotchAnimationStyle: String, CaseIterable, Identifiable, Sendable {
    case spring, jelly, pop, smooth, snappy, instant

    public var id: Self { self }

    public var title: String {
        switch self {
        case .spring: "Spring"
        case .jelly: "Jelly"
        case .pop: "Pop"
        case .smooth: "Smooth"
        case .snappy: "Snappy"
        case .instant: "Instant"
        }
    }

    public var summary: String {
        switch self {
        case .spring: "A balanced spring with a hint of bounce."
        case .jelly: "Squashes wide, stretches down, and wobbles into place."
        case .pop: "Springs up from slightly smaller with a quick bounce."
        case .smooth: "Eases in and out, no bounce."
        case .snappy: "Quick and crisp."
        case .instant: "No animation."
        }
    }
}

/// What a display without a notch shows: a stand-in notch as tall as its menu bar, or a floating pill.
public enum NotchlessStyle: String, CaseIterable, Identifiable, Sendable {
    case notch, pill

    public var id: Self { self }

    public var title: String {
        switch self {
        case .notch: "Notch"
        case .pill: "Pill"
        }
    }
}

/// A keyboard shortcut, kept the way Carbon's hot keys take it: a virtual key code, the same on
/// every keyboard layout, and Carbon modifier flags. `key` is what that key typed when recorded.
public struct KeyShortcut: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var key: String

    // Carbon's modifier flags (Events.h), which don't need Carbon to compare.
    public static let command: UInt32 = 0x100
    public static let shift: UInt32 = 0x200
    public static let option: UInt32 = 0x800
    public static let control: UInt32 = 0x1000

    public init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// "⌃⌥O": the modifiers in the order macOS menus show them, then the key.
    public var display: String {
        let symbols: [(UInt32, String)] = [
            (Self.control, "⌃"), (Self.option, "⌥"), (Self.shift, "⇧"), (Self.command, "⌘"),
        ]
        return symbols.filter { modifiers & $0.0 != 0 }.map(\.1).joined() + key
    }
}

/// User preferences, persisted in UserDefaults. The settings UI binds to these directly.
@MainActor
@Observable
public final class NotchPreferences {
    /// Features the user turned off. Stored this way round so features added in later versions
    /// start out enabled.
    public private(set) var disabledFeatures: Set<FeatureID> {
        didSet { defaults.set(disabledFeatures.map(\.rawValue).sorted(), forKey: Key.disabledFeatures) }
    }

    /// Every space, in the order the user arranged them, hidden ones too. The deck's wings show the
    /// shown ones in this order.
    public private(set) var spaceOrder: [SpaceID] {
        didSet { defaults.set(spaceOrder.map(\.rawValue), forKey: Key.spaceOrder) }
    }

    /// Spaces the user hid. Stored this way round so a space added later starts out shown.
    public private(set) var hiddenSpaces: Set<SpaceID> {
        didSet { defaults.set(hiddenSpaces.map(\.rawValue).sorted(), forKey: Key.hiddenSpaces) }
    }

    /// Show a notch on every display, not just the built-in (or main) one.
    public var showOnAllDisplays: Bool {
        didSet { defaults.set(showOnAllDisplays, forKey: Key.showOnAllDisplays) }
    }

    /// Displays without a notch that show the floating pill, by display UUID; the rest get a notch.
    public private(set) var pillDisplays: Set<String> {
        didSet { defaults.set(pillDisplays.sorted(), forKey: Key.pillDisplays) }
    }

    public func notchlessStyle(for display: String) -> NotchlessStyle {
        pillDisplays.contains(display) ? .pill : .notch
    }

    public func setNotchlessStyle(_ style: NotchlessStyle, for display: String) {
        if style == .pill { pillDisplays.insert(display) } else { pillDisplays.remove(display) }
    }

    /// How the notch opens and closes.
    public var animationStyle: NotchAnimationStyle {
        didSet { defaults.set(animationStyle.rawValue, forKey: Key.animationStyle) }
    }

    /// A live activity when the volume changes or mutes.
    public var showsVolume: Bool {
        didSet { defaults.set(showsVolume, forKey: Key.showsVolume) }
    }

    /// A live activity when the charger connects or disconnects, the battery runs low, or it's full.
    public var showsBattery: Bool {
        didSet { defaults.set(showsBattery, forKey: Key.showsBattery) }
    }

    /// The notch shows volume changes instead of macOS's own display. Needs Accessibility access to
    /// catch the volume keys; off until the user turns it on.
    public var replacesVolumeDisplay: Bool {
        didSet { defaults.set(replacesVolumeDisplay, forKey: Key.replacesVolumeDisplay) }
    }

    /// Experimental: a Bluetooth keyboard, mouse, or trackpad's battery when it connects.
    public var showsAccessoryBattery: Bool {
        didSet { defaults.set(showsAccessoryBattery, forKey: Key.showsAccessoryBattery) }
    }

    /// Opens and closes the notch from any app. Nil once the user clears it.
    public var notchShortcut: KeyShortcut? {
        didSet {
            // Empty data means cleared; no value at all means the default.
            let data = notchShortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
            defaults.set(data, forKey: Key.notchShortcut)
        }
    }

    // ponytail: ⌃⌥O for "open", as Notes has ⌃⌥N for a new note; Settings changes it.
    public nonisolated static let defaultNotchShortcut = KeyShortcut(
        keyCode: 31, modifiers: KeyShortcut.control | KeyShortcut.option, key: "O")

    /// Opens the Clipboard tab from any app, ready to search. Nil once the user clears it.
    public var clipboardShortcut: KeyShortcut? {
        didSet {
            let data = clipboardShortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
            defaults.set(data, forKey: Key.clipboardShortcut)
        }
    }

    /// ⌃⌥V: V for paste, beside the notch's ⌃⌥O.
    public nonisolated static let defaultClipboardShortcut = KeyShortcut(
        keyCode: 9, modifiers: KeyShortcut.control | KeyShortcut.option, key: "V")

    /// The open deck's size, set by dragging its bottom-right corner. Always within the minimum and
    /// maximum.
    public private(set) var expandedSize: CGSize {
        didSet { defaults.set([expandedSize.width, expandedSize.height], forKey: Key.expandedSize) }
    }

    public nonisolated static let defaultExpandedSize = CGSize(width: 700, height: 430)
    /// Narrowest that still fits both wings and the camera between them, and the shortest that still
    /// fits each space's content.
    public nonisolated static let minimumExpandedSize = CGSize(width: 620, height: 340)
    public nonisolated static let maximumExpandedSize = CGSize(width: 900, height: 560)
    /// What VoiceOver's adjust steps through on the resize corner, smallest first: the minimum, then
    /// the default size scaled up, so the height follows the width.
    public nonisolated static let expandedSizeSteps =
        [minimumExpandedSize]
        + ([1, 1.1, 1.2, 1.28] as [CGFloat]).map { scale in
            let size = defaultExpandedSize
            return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        }

    /// Features that start off: turning those on is the user's call.
    public nonisolated static let offByDefault: Set<FeatureID> = [.storage, .admin]

    @ObservationIgnored private let defaults: UserDefaults
    /// Features this build can offer, in tab order. The App Store edition leaves out the ones the
    /// App Sandbox can't run.
    public let available: [FeatureID]

    public init(defaults: UserDefaults = .standard, unavailable: Set<FeatureID> = []) {
        self.defaults = defaults
        let available = FeatureID.allCases.filter { !unavailable.contains($0) }
        self.available = available
        func features(_ key: String) -> Set<FeatureID> {
            Set((defaults.stringArray(forKey: key) ?? []).compactMap(FeatureID.init(rawValue:)))
        }
        // A feature that's off by default starts off the first time this Mac sees it, including on
        // an update that adds it; after that the stored choice wins.
        let disabled = features(Key.disabledFeatures).union(Self.offByDefault.subtracting(features(Key.seenFeatures)))
        disabledFeatures = disabled
        defaults.set(disabled.map(\.rawValue).sorted(), forKey: Key.disabledFeatures)
        defaults.set(FeatureID.allCases.map(\.rawValue), forKey: Key.seenFeatures)
        // The stored order, then whatever it doesn't know yet (a space added by an update) at the end.
        var placed: Set<SpaceID> = []
        let storedSpaces = (defaults.stringArray(forKey: Key.spaceOrder) ?? []).flatMap(SpaceID.stored)
            .filter { placed.insert($0).inserted }
        spaceOrder = storedSpaces + SpaceID.allCases.filter { !placed.contains($0) }
        hiddenSpaces = Set((defaults.stringArray(forKey: Key.hiddenSpaces) ?? []).flatMap(SpaceID.stored))
        showOnAllDisplays = defaults.bool(forKey: Key.showOnAllDisplays)
        pillDisplays = Set(defaults.stringArray(forKey: Key.pillDisplays) ?? [])
        animationStyle = defaults.string(forKey: Key.animationStyle).flatMap(NotchAnimationStyle.init) ?? .spring
        showsVolume = defaults.object(forKey: Key.showsVolume) as? Bool ?? true
        showsBattery = defaults.object(forKey: Key.showsBattery) as? Bool ?? true
        replacesVolumeDisplay = defaults.bool(forKey: Key.replacesVolumeDisplay)
        showsAccessoryBattery = defaults.bool(forKey: Key.showsAccessoryBattery)
        // Stored empty means cleared; nothing stored means the default.
        func shortcut(_ key: String, default value: KeyShortcut) -> KeyShortcut? {
            guard let data = defaults.data(forKey: key) else { return value }
            return try? JSONDecoder().decode(KeyShortcut.self, from: data)
        }
        notchShortcut = shortcut(Key.notchShortcut, default: Self.defaultNotchShortcut)
        clipboardShortcut = shortcut(Key.clipboardShortcut, default: Self.defaultClipboardShortcut)
        if let size = defaults.array(forKey: Key.expandedSize) as? [Double], size.count == 2 {
            expandedSize = Self.clamped(CGSize(width: size[0], height: size[1]))
        } else {
            expandedSize = Self.defaultExpandedSize
        }
    }

    /// Resizes the open notch, keeping it within the minimum and maximum.
    public func resizeExpanded(to size: CGSize) {
        expandedSize = Self.clamped(size)
    }

    /// The next size up or down from the current one, or nil at the largest or smallest. Steps are
    /// ordered by area, since the two smallest share a width.
    public func expandedSizeStep(larger: Bool) -> CGSize? {
        let area = expandedSize.width * expandedSize.height
        let steps = Self.expandedSizeSteps
        return larger
            ? steps.first { $0.width * $0.height > area + 1 } : steps.last { $0.width * $0.height < area - 1 }
    }

    nonisolated static func clamped(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minimumExpandedSize.width), maximumExpandedSize.width),
            height: min(max(size.height, minimumExpandedSize.height), maximumExpandedSize.height))
    }

    /// Features that are on.
    public var enabledFeatures: [FeatureID] { available.filter { !disabledFeatures.contains($0) } }

    public func isEnabled(_ feature: FeatureID) -> Bool { !disabledFeatures.contains(feature) }

    public func setEnabled(_ feature: FeatureID, _ enabled: Bool) {
        if enabled { disabledFeatures.remove(feature) } else { disabledFeatures.insert(feature) }
    }

    /// What the deck offers: the spaces to show, in order, and the features that are on.
    public var spaceSet: SpaceSet {
        SpaceSet(order: spaceOrder, hidden: hiddenSpaces, enabled: Set(enabledFeatures))
    }

    /// Hides or shows a space. The last one on show stays: the deck always has somewhere to open.
    public func setSpace(_ space: SpaceID, hidden: Bool) {
        if !hidden {
            hiddenSpaces.remove(space)
        } else if spaceSet.spaces != [space] {
            hiddenSpaces.insert(space)
        }
    }

    /// Moves `space` to `index` among all the spaces, hidden ones too.
    public func moveSpace(_ space: SpaceID, to index: Int) {
        var order = spaceOrder.filter { $0 != space }
        order.insert(space, at: min(max(index, 0), order.count))
        spaceOrder = order
    }

    /// Restores every preference to its default.
    public func reset() {
        disabledFeatures = Self.offByDefault
        spaceOrder = SpaceID.defaultOrder
        hiddenSpaces = []
        showOnAllDisplays = false
        pillDisplays = []
        animationStyle = .spring
        expandedSize = Self.defaultExpandedSize
        showsVolume = true
        showsBattery = true
        replacesVolumeDisplay = false
        showsAccessoryBattery = false
        notchShortcut = Self.defaultNotchShortcut
        clipboardShortcut = Self.defaultClipboardShortcut
    }

    private enum Key {
        static let disabledFeatures = "disabledFeatures"
        static let spaceOrder = "spaceOrder"
        static let hiddenSpaces = "hiddenSpaces"
        static let seenFeatures = "seenFeatures"
        static let showOnAllDisplays = "showOnAllDisplays"
        static let pillDisplays = "pillDisplays"
        static let animationStyle = "animationStyle"
        // Not the old tab row's "expandedSize": a size picked for that notch would be too small here.
        static let expandedSize = "deckSize"
        static let showsVolume = "showsVolume"
        static let showsBattery = "showsBattery"
        static let replacesVolumeDisplay = "replacesVolumeDisplay"
        static let showsAccessoryBattery = "showsAccessoryBattery"
        static let notchShortcut = "notchShortcut"
        static let clipboardShortcut = "clipboardShortcut"
    }
}

/// Calls `apply` now, then again after every change to an observable property it read.
@MainActor
public func observeContinuously(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking(apply) {
        Task { @MainActor in observeContinuously(apply) }
    }
}
