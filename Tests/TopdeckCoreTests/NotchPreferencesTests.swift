// SPDX-License-Identifier: MIT
import CoreGraphics
import Foundation
import Testing

@testable import TopdeckCore

@MainActor
struct NotchPreferencesTests {
    /// A throwaway defaults domain per test.
    private let defaults = UserDefaults(suiteName: "NotchPreferencesTests.\(UUID().uuidString)")!
    /// Every tab except those that start off.
    private let defaultTabs = FeatureID.allCases.filter { !NotchPreferences.offByDefault.contains($0) }

    @Test func everythingIsEnabledOnOneDisplayByDefault() {
        let preferences = NotchPreferences(defaults: defaults)
        #expect(preferences.enabledFeatures == defaultTabs)
        #expect(!preferences.showOnAllDisplays)
        #expect(preferences.showsVolume && preferences.showsBattery)
        #expect(!preferences.replacesVolumeDisplay && !preferences.showsAccessoryBattery)
    }

    @Test func choicesPersistAcrossLaunches() {
        let first = NotchPreferences(defaults: defaults)
        first.setEnabled(.media, false)
        first.showOnAllDisplays = true
        first.showsBattery = false

        let second = NotchPreferences(defaults: defaults)
        #expect(!second.isEnabled(.media))
        #expect(second.enabledFeatures == defaultTabs.filter { $0 != .media })
        #expect(second.showOnAllDisplays)
        #expect(!second.showsBattery)
    }

    @Test func unknownStoredFeaturesAreIgnored() {
        defaults.set(["notes", "a-feature-from-the-future"], forKey: "disabledFeatures")
        let disabled = NotchPreferences(defaults: defaults).disabledFeatures
        #expect(disabled == Set([.notes]).union(NotchPreferences.offByDefault))
    }

    @Test func spacesStartInTheirDefaultOrderAllShown() {
        let preferences = NotchPreferences(defaults: defaults)
        #expect(preferences.spaceOrder == [.now, .stash, .plan, .agents, .mac, .tools])
        #expect(preferences.spaceSet.spaces == SpaceID.defaultOrder)
    }

    @Test func spacesMoveAndKeepTheirPlaceWhileHidden() {
        let preferences = NotchPreferences(defaults: defaults)
        preferences.moveSpace(.tools, to: 1)
        #expect(preferences.spaceSet.spaces == [.now, .tools, .stash, .plan, .agents, .mac])
        preferences.setSpace(.stash, hidden: true)
        #expect(preferences.spaceSet.spaces == [.now, .tools, .plan, .agents, .mac])
        preferences.moveSpace(.mac, to: 99)
        preferences.moveSpace(.agents, to: -4)
        #expect(preferences.spaceOrder == [.agents, .now, .tools, .stash, .plan, .mac], "the hidden stash stayed")
        preferences.setSpace(.stash, hidden: false)
        let reopened = NotchPreferences(defaults: defaults)
        #expect(
            reopened.spaceSet.spaces == [.agents, .now, .tools, .stash, .plan, .mac], "order and visibility persist")
    }

    @Test func theLastSpaceOnShowCannotBeHidden() {
        let preferences = NotchPreferences(defaults: defaults)
        for space in SpaceID.allCases { preferences.setSpace(space, hidden: true) }
        #expect(preferences.spaceSet.spaces == [.tools], "the last one asked to hide stays")
        #expect(preferences.hiddenSpaces == Set(SpaceID.allCases).subtracting([.tools]))
    }

    @Test func aSpaceWithNothingOnIsHidden() {
        let preferences = NotchPreferences(defaults: defaults)
        for feature in SpaceID.plan.features { preferences.setEnabled(feature, false) }
        #expect(preferences.spaceSet.spaces == [.now, .stash, .agents, .mac, .tools], "calendar and tasks are off")
        preferences.setEnabled(.calendar, true)
        #expect(preferences.spaceSet.spaces.contains(.plan))
    }

    @Test func aSpaceAddedByAnUpdateJoinsTheEndOfACustomOrder() {
        defaults.set(["tools", "now", "a-space-from-the-future", "tools"], forKey: "spaceOrder")
        let order = NotchPreferences(defaults: defaults).spaceOrder
        #expect(order.prefix(2) == [.tools, .now])
        #expect(Array(order.dropFirst(2)) == SpaceID.allCases.filter { $0 != .tools && $0 != .now })
        #expect(!NotchPreferences(defaults: defaults, unavailable: [.usage]).enabledFeatures.contains(.usage))
    }

    @Test func resetRestoresTheDefaults() {
        let preferences = NotchPreferences(defaults: defaults)
        preferences.moveSpace(.tools, to: 0)
        preferences.setSpace(.plan, hidden: true)
        preferences.setEnabled(.shelf, false)
        preferences.showOnAllDisplays = true
        preferences.resizeExpanded(to: CGSize(width: 800, height: 400))
        preferences.setEnabled(.notes, false)
        preferences.replacesVolumeDisplay = true
        preferences.reset()
        #expect(preferences.enabledFeatures == defaultTabs)
        #expect(preferences.spaceOrder == SpaceID.defaultOrder && preferences.hiddenSpaces.isEmpty)
        #expect(preferences.expandedSize == NotchPreferences.defaultExpandedSize)
        #expect(!preferences.replacesVolumeDisplay)
        #expect(!NotchPreferences(defaults: defaults).showOnAllDisplays)
    }

    @Test func theNotchSizePersistsWithinItsLimits() {
        let preferences = NotchPreferences(defaults: defaults)
        #expect(preferences.expandedSize == CGSize(width: 700, height: 430), "the deck's default size")
        preferences.resizeExpanded(to: CGSize(width: 800, height: 380))
        #expect(NotchPreferences(defaults: defaults).expandedSize == CGSize(width: 800, height: 380))
        preferences.resizeExpanded(to: CGSize(width: 5000, height: 10))
        #expect(preferences.expandedSize == CGSize(width: 900, height: 340))
        defaults.set([10.0, 9999.0], forKey: "deckSize")  // a hand-edited value is clamped too
        #expect(NotchPreferences(defaults: defaults).expandedSize == CGSize(width: 620, height: 560))
    }

    @Test func aSizeFromTheOldNotchIsLeftBehind() {
        defaults.set([460.0, 290.0], forKey: "expandedSize")
        #expect(NotchPreferences(defaults: defaults).expandedSize == NotchPreferences.defaultExpandedSize)
    }

    @Test func theAnimationStylePersistsAndFallsBackToSpring() {
        #expect(NotchPreferences(defaults: defaults).animationStyle == .spring)
        NotchPreferences(defaults: defaults).animationStyle = .jelly
        #expect(NotchPreferences(defaults: defaults).animationStyle == .jelly)
        defaults.set("wobbly-from-the-future", forKey: "animationStyle")
        #expect(NotchPreferences(defaults: defaults).animationStyle == .spring)
    }

    @Test func theNotchShortcutStartsAsControlOptionOAndCanBeChangedOrCleared() {
        #expect(NotchPreferences(defaults: defaults).notchShortcut?.display == "⌃⌥O")
        #expect(NotchPreferences(defaults: defaults).clipboardShortcut?.display == "⌃⌥V")
        let command = KeyShortcut(keyCode: 49, modifiers: KeyShortcut.command | KeyShortcut.shift, key: "Space")
        NotchPreferences(defaults: defaults).notchShortcut = command
        #expect(NotchPreferences(defaults: defaults).notchShortcut == command)
        #expect(command.display == "⇧⌘Space", "modifiers read in the order menus show them")
        let cleared = NotchPreferences(defaults: defaults)
        cleared.notchShortcut = nil
        #expect(NotchPreferences(defaults: defaults).notchShortcut == nil, "cleared stays cleared")
        cleared.reset()
        #expect(NotchPreferences(defaults: defaults).notchShortcut == NotchPreferences.defaultNotchShortcut)
    }

    @Test func displaysWithoutANotchGetOneUnlessThePillIsPicked() {
        let preferences = NotchPreferences(defaults: defaults)
        #expect(preferences.notchlessStyle(for: "studio-display") == .notch)
        preferences.setNotchlessStyle(.pill, for: "studio-display")
        #expect(NotchPreferences(defaults: defaults).notchlessStyle(for: "studio-display") == .pill)
        #expect(NotchPreferences(defaults: defaults).notchlessStyle(for: "another-display") == .notch)
        preferences.reset()
        #expect(NotchPreferences(defaults: defaults).notchlessStyle(for: "studio-display") == .notch)
    }

    @Test func plusAndMinusResizeInProportion() {
        let preferences = NotchPreferences(defaults: defaults)
        var larger: [CGSize] = []
        while let next = preferences.expandedSizeStep(larger: true) {
            preferences.resizeExpanded(to: next)
            larger.append(preferences.expandedSize)
        }
        #expect(larger.map(\.width) == [770, 840, 896], "+ stops at the largest size")
        var smaller: [CGSize] = []
        while let next = preferences.expandedSizeStep(larger: false) {
            preferences.resizeExpanded(to: next)
            smaller.append(preferences.expandedSize)
        }
        #expect(smaller.map(\.width) == [840, 770, 700, 620], "− steps back down")
        #expect(smaller.last == NotchPreferences.minimumExpandedSize)

        let steps = NotchPreferences.expandedSizeSteps
        let aspect = NotchPreferences.defaultExpandedSize.width / NotchPreferences.defaultExpandedSize.height
        for step in steps.dropFirst() {
            #expect(abs(step.width / step.height - aspect) < 0.01, "the height follows the width")
        }
        #expect(steps.allSatisfy { NotchPreferences.clamped($0) == $0 }, "every step is within the limits")
    }

    @Test func observersRerunAfterEveryChange() async throws {
        let preferences = NotchPreferences(defaults: defaults)
        var seen: [[FeatureID]] = []
        observeContinuously { seen.append(preferences.enabledFeatures) }
        preferences.setEnabled(.tasks, false)
        #expect(await eventually { seen.count == 2 })
        preferences.setEnabled(.tasks, true)
        #expect(await eventually { seen.count == 3 })
        #expect(seen.last == defaultTabs)
    }
}
