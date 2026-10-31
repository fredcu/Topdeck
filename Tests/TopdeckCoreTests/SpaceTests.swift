// SPDX-License-Identifier: MIT
import Testing

@testable import TopdeckCore

struct SpaceTests {
    @Test func theFiveSpacesAreInTheSpecsOrder() {
        #expect(SpaceID.defaultOrder.map(\.title) == ["Now", "Stash", "Tools", "Agents", "Mac"])
        let wings = SpaceSet.all.wings
        #expect(wings.left == [.now, .stash, .tools] && wings.right == [.agents, .mac])
    }

    @Test func subTabsAreStashAgentsAndMacOnly() {
        #expect(SpaceID.allCases.filter(\.hasSubTabs) == [.stash, .agents, .mac])
        #expect(SpaceSet.all.subTabs(of: .stash) == [.shelf, .clipboard, .notes])
        #expect(SpaceSet.all.subTabs(of: .agents) == [.agents, .usage])
        #expect(SpaceSet.all.subTabs(of: .mac) == [.performance, .sound, .monitors, .network, .storage, .admin])
        #expect(SpaceSet.all.subTabs(of: .now).isEmpty && SpaceSet.all.subTabs(of: .tools).isEmpty)
        let titles = SpaceSet.all.subTabs(of: .mac).map { SpaceID.mac.subTabTitle($0) }
        #expect(titles == ["Performance", "Sound", "Displays", "Network", "Storage", "System"])
        #expect(SpaceID.agents.subTabTitle(.agents) == "Sessions" && SpaceID.agents.subTabTitle(.usage) == "Usage")
    }

    @Test func eachFeatureHasOneHomeAmongTheSpacesThatHoldIt() {
        for feature in FeatureID.allCases {
            #expect(feature.home.features.contains(feature), "\(feature) is not in \(feature.home)")
        }
        #expect(
            FeatureID.allCases.allSatisfy { feature in
                SpaceID.allCases.contains { $0.features.contains(feature) }
            }, "no feature is left without a screen")
        #expect(FeatureID.clipboard.subTabSpace == .stash && FeatureID.timer.subTabSpace == nil)
    }

    @Test func aSubTabbedSpaceShowsOnlyTheChosenFeature() {
        #expect(SpaceSet.all.visibleFeatures(in: .stash, subTab: .notes) == [.notes])
        #expect(SpaceSet.all.visibleFeatures(in: .stash, subTab: nil).isEmpty)
        #expect(
            SpaceSet.all.visibleFeatures(in: .now, subTab: nil) == [
                .media, .agents, .calendar, .notes, .weather, .timer,
            ],
            "everything Now shows")
        #expect(
            SpaceSet.all.visibleFeatures(in: .mac, subTab: .sound) == [.sound, .monitors],
            "Sound shows the monitors' volume")
        #expect(SpaceSet(enabled: [.sound]).visibleFeatures(in: .mac, subTab: .sound) == [.sound])
    }

    @Test func aSpaceWithNothingOnIsHidden() {
        let set = SpaceSet(enabled: [.notes, .performance])
        #expect(set.spaces == [.now, .stash, .mac], "Now stays; agents and tools have nothing on")
        #expect(set.subTabs(of: .stash) == [.notes] && set.subTabs(of: .mac) == [.performance])
    }

    @Test func hiddenSpacesLeaveAndTheRestKeepTheirOrder() {
        let set = SpaceSet(
            order: [.tools, .mac, .now, .stash, .agents], hidden: [.mac], enabled: Set(FeatureID.allCases)
        )
        #expect(set.spaces == [.tools, .now, .stash, .agents])
    }

    @Test func thereIsAlwaysSomewhereToOpen() {
        #expect(SpaceSet(hidden: Set(SpaceID.allCases), enabled: []).spaces == [.now])
        #expect(SpaceSet(order: [], enabled: []).spaces == [.now])
    }

    @Test func theWingsSplitWithTheLeftTakingTheExtra() {
        func wings(_ hidden: Set<SpaceID>) -> ([SpaceID], [SpaceID]) {
            let set = SpaceSet(hidden: hidden, enabled: Set(FeatureID.allCases))
            return (set.wings.left, set.wings.right)
        }
        #expect(wings([.tools]) == ([.now, .stash], [.agents, .mac]))
        #expect(wings([.tools, .mac]) == ([.now, .stash], [.agents]))
        let one = SpaceSet(hidden: Set(SpaceID.allCases).subtracting([.mac]), enabled: Set(FeatureID.allCases))
        #expect(one.wings.left == [.mac] && one.wings.right.isEmpty)
    }

    @Test func aFeatureOpensItsHomeOrAnotherSpaceThatHoldsIt() {
        let all = Set(FeatureID.allCases)
        #expect(SpaceSet.all.target(for: .calendar) == .now && SpaceSet.all.target(for: .weather) == .now)
        #expect(SpaceSet(hidden: [.now], enabled: all).target(for: .calendar) == nil)
        #expect(SpaceSet(hidden: [.stash], enabled: all).target(for: .notes) == .now, "Now shows notes too")
        #expect(SpaceSet(hidden: [.mac], enabled: all).target(for: .sound) == nil)
    }
}
