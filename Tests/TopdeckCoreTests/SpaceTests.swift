// SPDX-License-Identifier: MIT
import Testing

@testable import TopdeckCore

struct SpaceTests {
    @Test func theSixSpacesAreInTheSpecsOrder() {
        #expect(SpaceID.defaultOrder.map(\.title) == ["Now", "Shelf", "Clipboard", "Tools", "Agents", "Mac"])
        let wings = SpaceSet.all.wings
        #expect(wings.left == [.now, .shelf, .clipboard] && wings.right == [.tools, .agents, .mac])
    }

    @Test func aStoredStashStandsForShelfAndClipboard() {
        #expect(SpaceID.stored("stash") == [.shelf, .clipboard])
        #expect(SpaceID.stored("mac") == [.mac] && SpaceID.stored("plan").isEmpty)
        #expect(SpaceID(rawValue: "stash") == nil, "there is no Stash space any more")
    }

    @Test func macHasFiveDetailScreensAndNoOtherSpaceHasAny() {
        #expect(SpaceID.mac.details == [.sound, .monitors, .network, .storage, .admin])
        #expect(SpaceID.allCases.filter { !$0.details.isEmpty } == [.mac])
        let titles = SpaceID.mac.details.map { SpaceID.mac.detailTitle($0) }
        #expect(titles == ["Sound", "Displays", "Network", "Storage", "System"])
        #expect(FeatureID.storage.detailSpace == .mac && FeatureID.performance.detailSpace == nil)
    }

    @Test func systemIsOpenableAsSoonAsPerformanceOrSystemAdminIsOn() {
        #expect(SpaceID.mac.openableDetails(enabled: Set(FeatureID.allCases)) == SpaceID.mac.details)
        #expect(SpaceID.mac.openableDetails(enabled: [.performance]) == [.admin])
        #expect(SpaceID.mac.openableDetails(enabled: [.admin, .sound]) == [.sound, .admin])
        #expect(SpaceID.mac.openableDetails(enabled: [.sound]) == [.sound])
        #expect(SpaceID.tools.openableDetails(enabled: [.performance]).isEmpty)
    }

    @Test func eachFeatureHasOneHomeAmongTheSpacesThatHoldIt() {
        for feature in FeatureID.allCases {
            #expect(feature.home.features.contains(feature), "\(feature) is not in \(feature.home)")
        }
        #expect(
            FeatureID.allCases.allSatisfy { feature in
                SpaceID.allCases.contains { $0.features.contains(feature) }
            }, "no feature is left without a screen")
        #expect(FeatureID.clipboard.detailSpace == nil && FeatureID.timer.detailSpace == nil)
        #expect(
            FeatureID.notes.home == .now && FeatureID.shelf.home == .shelf && FeatureID.clipboard.home == .clipboard)
    }

    @Test func aSpaceShowsAllItsFeaturesOnOnePage() {
        #expect(SpaceSet.all.visibleFeatures(in: .agents, detail: nil) == [.agents, .usage])
        #expect(SpaceSet.all.visibleFeatures(in: .shelf, detail: nil) == [.shelf])
        #expect(SpaceSet.all.visibleFeatures(in: .tools, detail: nil) == [.capture, .timer, .shortcuts])
        #expect(
            SpaceSet.all.visibleFeatures(in: .now, detail: nil) == [
                .media, .agents, .calendar, .notes, .weather, .timer,
            ],
            "everything Now shows")
    }

    @Test func macRunsItsPageAndOnlyTheDetailScreenThatIsOver() {
        #expect(SpaceSet.all.visibleFeatures(in: .mac, detail: nil) == [.performance, .monitors])
        #expect(SpaceSet.all.visibleFeatures(in: .mac, detail: .storage) == [.performance, .monitors, .storage])
        #expect(
            SpaceSet.all.visibleFeatures(in: .mac, detail: .sound) == [.performance, .monitors, .sound],
            "Sound shows the monitors' volume")
        #expect(SpaceSet(enabled: [.sound]).visibleFeatures(in: .mac, detail: .sound) == [.sound])
        #expect(
            SpaceSet.all.visibleFeatures(in: .mac, detail: .capture) == [.performance, .monitors], "not a Mac detail")
        #expect(SpaceSet(enabled: [.performance]).visibleFeatures(in: .mac, detail: .storage) == [.performance])
    }

    @Test func aSpaceWithNothingOnIsHidden() {
        let set = SpaceSet(enabled: [.shelf, .performance])
        #expect(set.spaces == [.now, .shelf, .mac], "Now stays; clipboard, agents and tools have nothing on")
    }

    @Test func hiddenSpacesLeaveAndTheRestKeepTheirOrder() {
        let set = SpaceSet(
            order: [.tools, .mac, .now, .shelf, .agents, .clipboard], hidden: [.mac],
            enabled: Set(FeatureID.allCases)
        )
        #expect(set.spaces == [.tools, .now, .shelf, .agents, .clipboard])
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
        #expect(wings([.tools]) == ([.now, .shelf, .clipboard], [.agents, .mac]))
        #expect(wings([.tools, .mac]) == ([.now, .shelf], [.clipboard, .agents]))
        let one = SpaceSet(hidden: Set(SpaceID.allCases).subtracting([.mac]), enabled: Set(FeatureID.allCases))
        #expect(one.wings.left == [.mac] && one.wings.right.isEmpty)
    }

    @Test func aPageHasASecondRowOnlyWhenItHasSomethingOfItsOwnForIt() {
        func row(_ space: SpaceID, shelf: Bool = false, history: Bool = false, agents: Bool = true) -> Bool {
            space.hasSecondRow(shelfFilled: shelf, clipboardHistory: history, agentsRow: agents)
        }
        #expect(row(.now), "the clock, the slot and the actions")
        #expect(!row(.shelf) && row(.shelf, shelf: true), "files bring their count and actions")
        #expect(!row(.clipboard) && row(.clipboard, history: true), "history on brings its filters")
        #expect(!row(.tools) && !row(.mac, shelf: true, history: true), "never, whatever else is on")
        #expect(row(.agents) && !row(.agents, agents: false), "its period and refresh, while usage is on")
    }

    @Test func aFeatureOpensItsHomeOrAnotherSpaceThatHoldsIt() {
        let all = Set(FeatureID.allCases)
        #expect(SpaceSet.all.target(for: .calendar) == .now && SpaceSet.all.target(for: .weather) == .now)
        #expect(SpaceSet(hidden: [.now], enabled: all).target(for: .calendar) == nil)
        #expect(SpaceSet(hidden: [.shelf], enabled: all).target(for: .shelf) == nil)
        #expect(SpaceSet(hidden: [.clipboard], enabled: all).target(for: .notes) == .now)
        #expect(SpaceSet(hidden: [.mac], enabled: all).target(for: .sound) == nil)
    }
}
