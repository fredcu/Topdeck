// SPDX-License-Identifier: MIT

/// A screen of the deck. Six of them replace the old tab row: three in the left wing, three in the
/// right. Each holds one or more features' views; a space with sub-tabs shows one feature at a time.
public enum SpaceID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case now, stash, plan, agents, mac, tools

    public var id: Self { self }

    /// The label in the wing. Text only, no icon.
    public var title: String {
        switch self {
        case .now: "Now"
        case .stash: "Stash"
        case .plan: "Plan"
        case .agents: "Agents"
        case .mac: "Mac"
        case .tools: "Tools"
        }
    }

    /// Where the spaces start out, left wing first.
    public static let defaultOrder: [SpaceID] = allCases

    /// The features whose views the space shows. With sub-tabs, one tab each, in tab order; without,
    /// all of them on one screen.
    public var features: [FeatureID] {
        switch self {
        case .now: [.media, .agents, .calendar, .tasks, .timer]
        case .stash: [.shelf, .clipboard, .notes]
        case .plan: [.calendar, .tasks]
        case .agents: [.agents, .usage]
        case .mac: [.performance, .sound, .monitors, .network, .storage, .admin]
        case .tools: [.capture, .timer, .shortcuts]
        }
    }

    /// Whether the space shows one feature at a time under sub-tabs.
    public var hasSubTabs: Bool {
        switch self {
        case .stash, .agents, .mac: true
        case .now, .plan, .tools: false
        }
    }

    /// A sub-tab's label, which can differ from its feature's name (Agents' tab is Sessions).
    public func subTabTitle(_ feature: FeatureID) -> String {
        switch (self, feature) {
        case (.agents, .agents): "Sessions"
        case (.agents, .usage): "Usage"
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
        case .media: .now
        case .shelf, .clipboard, .notes: .stash
        case .calendar, .tasks: .plan
        case .agents, .usage: .agents
        case .sound, .monitors, .network, .storage, .admin, .performance: .mac
        case .capture, .shortcuts, .timer: .tools
        }
    }

    /// The sub-tabbed space this feature is a tab of, if it is one.
    public var subTabSpace: SpaceID? {
        SpaceID.allCases.first { $0.hasSubTabs && $0.features.contains(self) }
    }
}

/// What the deck offers right now: which spaces are on show, in order, and which features are on.
/// Pure, so the rules (a space with nothing on is hidden, a sub-tab for a feature that is off is
/// hidden) are tested without any UI.
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

    /// A sub-tabbed space's tabs: its features that are on, in tab order. Empty for a space without sub-tabs.
    public func subTabs(of space: SpaceID) -> [FeatureID] {
        space.hasSubTabs ? space.features.filter(enabled.contains) : []
    }

    /// The features a space shows on screen at once when `subTab` is chosen.
    public func visibleFeatures(in space: SpaceID, subTab: FeatureID?) -> Set<FeatureID> {
        if space.hasSubTabs { return subTab.map { [$0] } ?? [] }
        return Set(space.features.filter(enabled.contains))
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
