// SPDX-License-Identifier: MIT
// Adapted from MacTools (https://github.com/mactools-app/MacTools) at 9197035: Plugins/AutoInput/Sources/
// AutoInputModels.swift and AutoInputStore.swift. Copyright (c) 2026 ggbond268. Apache License 2.0; changed for
// Topdeck. See THIRD_PARTY_NOTICES.md.
import Foundation

/// A keyboard input source the user has turned on: a layout such as ABC, or an input mode such as Pinyin.
public struct InputSource: Identifiable, Hashable, Sendable {
    /// The system's ID, such as `com.apple.keylayout.ABC` or `com.apple.inputmethod.SCIM.ITABC`.
    public let id: String
    public let name: String
    /// Its languages, most important first, as BCP 47 codes.
    public let languages: [String]

    public init(id: String, name: String, languages: [String] = []) {
        self.id = id
        self.name = name
        self.languages = languages
    }

    /// Chinese, Japanese, Korean, or Vietnamese. Selecting one of these from another app can leave the
    /// focused app typing with the old source while the menu bar shows the new one, until its key
    /// window changes.
    public var isCJKV: Bool {
        guard let language = languages.first?.lowercased() else { return false }
        return language == "ja" || language == "ko" || language == "vi" || language.hasPrefix("zh")
    }
}

/// An app as the switcher sees it: its bundle ID, and the name to show for it.
public struct InputSwitchApp: Hashable, Sendable {
    public let bundleID: String
    public let name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Which input source each app gets. An app the user set a source for always gets that one. Otherwise
/// it gets the source it was last left with, while the switcher remembers those.
public struct InputSwitchRules: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var name: String
        /// Chosen by the user: always this source in this app.
        public var fixed: String?
        /// The source the app was last left with.
        public var remembered: String?
    }

    /// Why an app gets a source.
    public enum Reason: Equatable, Sendable { case fixed, remembered }

    public struct Choice: Equatable, Sendable {
        public let sourceID: String
        public let reason: Reason
    }

    /// Keyed by bundle ID.
    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    /// The source `bundleID` should switch to, among the sources turned on now. A fixed source that
    /// was turned off since falls back to the remembered one; nil leaves the current source alone.
    public func choice(for bundleID: String, available: Set<String>, remembers: Bool) -> Choice? {
        guard let entry = entries[bundleID] else { return nil }
        if let fixed = entry.fixed, available.contains(fixed) { return Choice(sourceID: fixed, reason: .fixed) }
        if remembers, let remembered = entry.remembered, available.contains(remembered) {
            return Choice(sourceID: remembered, reason: .remembered)
        }
        return nil
    }

    /// Always `sourceID` in `app`; nil goes back to remembering.
    public mutating func fix(_ sourceID: String?, for app: InputSwitchApp) {
        guard !app.bundleID.isEmpty else { return }
        var entry = entries[app.bundleID] ?? Entry(name: app.name)
        entry.name = app.name
        entry.fixed = sourceID.flatMap { $0.isEmpty ? nil : $0 }
        store(entry, for: app.bundleID)
    }

    /// `app` was left with `sourceID`.
    public mutating func remember(_ sourceID: String, for app: InputSwitchApp) {
        guard !app.bundleID.isEmpty, !sourceID.isEmpty else { return }
        var entry = entries[app.bundleID] ?? Entry(name: app.name)
        entry.name = app.name
        entry.remembered = sourceID
        store(entry, for: app.bundleID)
    }

    /// Drops every remembered source and keeps the fixed ones.
    public mutating func forgetRemembered() {
        for bundleID in entries.keys { entries[bundleID]?.remembered = nil }
        entries = entries.filter { $0.value.fixed != nil }
    }

    /// Apps with a fixed source, by name.
    public var fixedApps: [InputSwitchApp] {
        entries.filter { $0.value.fixed != nil }
            .map { InputSwitchApp(bundleID: $0.key, name: $0.value.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public var hasRemembered: Bool { entries.values.contains { $0.remembered != nil } }

    private mutating func store(_ entry: Entry, for bundleID: String) {
        entries[bundleID] = entry.fixed == nil && entry.remembered == nil ? nil : entry
    }

    // Decoding drops entries a damaged or hand-edited file left with nothing in them.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([String: Entry].self, forKey: .entries)
        entries = decoded.compactMapValues { entry in
            var entry = entry
            if entry.fixed?.isEmpty == true { entry.fixed = nil }
            if entry.remembered?.isEmpty == true { entry.remembered = nil }
            return entry.fixed == nil && entry.remembered == nil ? nil : entry
        }
        .filter { !$0.key.isEmpty }
    }
}

/// The switcher's settings and rules in UserDefaults. The rules are one JSON value, so a change
/// writes them whole and a damaged value reads as no rules.
@MainActor
struct InputSwitchStore {
    private enum Key {
        static let enabled = "inputSwitch.enabled"
        static let remembers = "inputSwitch.remembers"
        static let rules = "inputSwitch.rules"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Off until the user turns it on: it changes how typing works in every app.
    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.enabled) }
    }

    var remembers: Bool {
        get { defaults.object(forKey: Key.remembers) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.remembers) }
    }

    var rules: InputSwitchRules {
        get {
            guard let data = defaults.data(forKey: Key.rules) else { return InputSwitchRules() }
            return (try? JSONDecoder().decode(InputSwitchRules.self, from: data)) ?? InputSwitchRules()
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.rules)
        }
    }
}
