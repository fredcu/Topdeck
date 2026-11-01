// SPDX-License-Identifier: MIT

/// A screen of the deck. Six of them replace the old tab row: three in each wing. Each holds one or
/// more features' views on one page.
public enum SpaceID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case now, shelf, clipboard, tools, agents, mac

    public var id: Self { self }

    /// The label in the wing. Text only, no icon.
    public var title: String {
        switch self {
        case .now: "Now"
        case .shelf: "Shelf"
        case .clipboard: "Clipboard"
        case .agents: "Agents"
        case .mac: "Mac"
        case .tools: "Tools"
        }
    }

    /// Where the spaces start out, left wing first.
    public static let defaultOrder: [SpaceID] = allCases

    /// The spaces a stored name stands for. Stash, which Shelf and Clipboard came out of, stands for both;
    /// a name no longer known stands for none.
    public static func stored(_ name: String) -> [SpaceID] {
        name == "stash" ? [.shelf, .clipboard] : SpaceID(rawValue: name).map { [$0] } ?? []
    }

    /// The features whose views the space shows, on its page or in the screens that slide over it.
    public var features: [FeatureID] {
        switch self {
        case .now: [.media, .agents, .calendar, .notes, .weather, .timer]
        case .shelf: [.shelf]
        case .clipboard: [.clipboard]
        case .agents: [.agents, .usage]
        case .mac: [.performance, .sound, .monitors, .network, .storage, .admin]
        case .tools: [.capture, .timer, .shortcuts]
        }
    }

    /// The screens that slide over the whole body of the space, each from a row on its page: Mac's
    /// Sound, Displays, Network, Storage and System. The others have none.
    public var details: [FeatureID] {
        self == .mac ? [.sound, .monitors, .network, .storage, .admin] : []
    }

    /// The detail screens that can open when `enabled` are on: those whose feature is, and Mac's System as soon as
    /// Performance is, since the process table it opens with is Performance's.
    public func openableDetails(enabled: Set<FeatureID>) -> [FeatureID] {
        details.filter { enabled.contains($0) || ($0 == .admin && enabled.contains(.performance)) }
    }

    /// Whether the page has anything for the second row. The top navigation already names the space, so a row
    /// with nothing of the page's own in it is not drawn, and the body moves up. Now and Agents (its period
    /// and refresh, while usage is on) keep theirs; the Shelf's holds its files, the Clipboard's its history.
    /// A detail screen always has one: its back button lives there.
    public func hasSecondRow(shelfFilled: Bool, clipboardHistory: Bool, agentsRow: Bool = true) -> Bool {
        switch self {
        case .now: true
        case .shelf: shelfFilled
        case .clipboard: clipboardHistory
        case .agents: agentsRow
        case .tools, .mac: false
        }
    }

    /// A detail screen's title, which can differ from its feature's name.
    public func detailTitle(_ feature: FeatureID) -> String {
        switch (self, feature) {
        case (.mac, .monitors): "Displays"
        case (.mac, .admin): "System"
        default: feature.title
        }
    }
}

extension FeatureID {
    /// The space that opens for this feature: where its live activity leads, and where its shortcut
    /// goes. Features that several spaces show (Calendar, Timer) belong to the one with their full view.
    public var home: SpaceID {
        switch self {
        case .media, .calendar, .weather, .notes: .now
        case .shelf: .shelf
        case .clipboard: .clipboard
        case .agents, .usage: .agents
        case .sound, .monitors, .network, .storage, .admin, .performance: .mac
        case .capture, .shortcuts, .timer: .tools
        }
    }

    /// The space whose detail screen this feature is, if it is one.
    public var detailSpace: SpaceID? {
        SpaceID.allCases.first { $0.details.contains(self) }
    }
}

/// What the deck offers right now: which spaces are on show, in order, and which features are on.
/// Pure, so the rules (a space with nothing on is hidden) are tested without any UI.
public struct SpaceSet: Hashable, Sendable {
    /// The spaces on show, in order. Never empty.
    public let spaces: [SpaceID]
    /// Features that are on.
    public let enabled: Set<FeatureID>

    /// `order` is the user's order of all spaces. A space is left out when the user hid it or when
    /// none of its features is on. Now stays unless hidden: with nothing to show it shows the date
    /// and clock. If everything would be left out, Now is shown anyway.
    public init(order: [SpaceID] = SpaceID.defaultOrder, hidden: Set<SpaceID> = [], enabled: Set<FeatureID>) {
        self.enabled = enabled
        let shown = order.filter { space in
            !hidden.contains(space) && (space == .now || space.features.contains(where: enabled.contains))
        }
        spaces = shown.isEmpty ? [.now] : shown
    }

    /// Every space, every feature on.
    public static let all = SpaceSet(enabled: Set(FeatureID.allCases))

    /// The features a space shows on screen at once. Mac's page runs Performance and Displays (for its brightness
    /// slider), and a detail screen's own feature too while one is over it, so the page's history carries on;
    /// the others show all of theirs.
    public func visibleFeatures(in space: SpaceID, detail: FeatureID?) -> Set<FeatureID> {
        guard space == .mac else { return Set(space.features.filter(enabled.contains)) }
        // The page reads the Mac's performance and the monitors' brightness; a detail screen adds its own work.
        var shown = Set([FeatureID.performance, .monitors].filter(enabled.contains))
        if let detail, enabled.contains(detail), space.details.contains(detail) {
            shown.insert(detail)
            // Sound also shows the external monitors' volume, so Displays runs while it's on screen.
            if detail == .sound, enabled.contains(.monitors) { shown.insert(.monitors) }
        }
        return shown
    }

    /// The space to open for `feature`: its home, else another space on show that holds it, else nil.
    public func target(for feature: FeatureID) -> SpaceID? {
        if spaces.contains(feature.home) { return feature.home }
        return spaces.first { $0.features.contains(feature) }
    }

    /// The two wings. The left takes the extra space when the count is odd.
    public var wings: (left: [SpaceID], right: [SpaceID]) {
        let split = (spaces.count + 1) / 2
        return (Array(spaces[..<split]), Array(spaces[split...]))
    }
}
