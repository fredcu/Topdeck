// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import TopdeckFeatures

private func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "MenuBarTests.\(UUID().uuidString)"))
}

private func position(_ name: String, _ defaults: UserDefaults) -> Double? {
    MenuBarLayout.position(name, in: defaults)
}

struct MenuBarLayoutTests {
    @Test func firstPlacementKeepsOurItemsRightOfTheExpanderInOrder() throws {
        let defaults = try makeDefaults()
        #expect(MenuBarLayout.place(in: defaults))
        #expect(position(MenuBarLayout.expanderName, defaults) == 380)
        #expect(position(MenuBarLayout.separatorName, defaults) == 362)
        #expect(position(MenuBarLayout.ownName, defaults) == 344)
        #expect(!MenuBarLayout.isSwallowed(in: defaults))
        #expect(!MenuBarLayout.place(in: defaults))  // nothing left to move
    }

    @Test func theExpanderIsTheUsersAndNeverMoves() throws {
        let defaults = try makeDefaults()
        defaults.set(500.0, forKey: MenuBarLayout.key(MenuBarLayout.expanderName))
        MenuBarLayout.place(in: defaults)
        #expect(position(MenuBarLayout.expanderName, defaults) == 500)
        #expect(position(MenuBarLayout.separatorName, defaults) == 482)
        #expect(position(MenuBarLayout.ownName, defaults) == 464)
    }

    @Test func anItemDraggedBehindTheExpanderIsFoundAndBroughtBack() throws {
        let defaults = try makeDefaults()
        MenuBarLayout.place(in: defaults)
        defaults.set(400.0, forKey: MenuBarLayout.key(MenuBarLayout.ownName))  // left of the expander
        #expect(MenuBarLayout.isSwallowed(in: defaults))
        #expect(MenuBarLayout.place(in: defaults))
        #expect(!MenuBarLayout.isSwallowed(in: defaults))
        #expect(position(MenuBarLayout.ownName, defaults) == 344)
    }

    @Test func anItemWithNoPositionCountsAsSwallowed() throws {
        #expect(MenuBarLayout.isSwallowed(in: try makeDefaults()))
    }

    @Test func removalKeepsTheStoredPositions() throws {
        let defaults = try makeDefaults()
        MenuBarLayout.place(in: defaults)
        let names = [MenuBarLayout.expanderName, MenuBarLayout.separatorName]
        let saved = MenuBarLayout.saved(names, in: defaults)
        for name in names { defaults.removeObject(forKey: MenuBarLayout.key(name)) }
        MenuBarLayout.restore(saved, in: defaults)
        #expect(position(MenuBarLayout.separatorName, defaults) == 362)
    }

    @Test func pushWidthDependsOnTheMacOSVersionAndTheNotch() {
        #expect(MenuBarLayout.pushWidth(screenWidths: [1512], macOS27: false) == 10_000)
        #expect(MenuBarLayout.pushWidth(screenWidths: [1512, 1000], macOS27: true) == 450)
        #expect(MenuBarLayout.pushWidth(screenWidths: [1512], macOS27: true, notchGap: 300) == 312)
        #expect(MenuBarLayout.pushWidth(screenWidths: [1512], macOS27: true, notchGap: 900) == 680)
        #expect(MenuBarLayout.pushWidth(screenWidths: [1512], macOS27: true, notchGap: 10) == 200)
    }
}

@MainActor
private final class FakeSurface: MenuBarSurface {
    var onClick: (() -> Void)?
    var installs = 0
    var removals = 0
    var collapsed: Bool?
    func install() { installs += 1 }
    func remove() {
        removals += 1
        collapsed = nil
    }
    func render(collapsed: Bool) { self.collapsed = collapsed }
}

@MainActor
struct MenuBarHiderTests {
    private func hider(enabled: Bool = true, delay: Double = 0.05) throws -> (MenuBarHider, FakeSurface) {
        let defaults = try makeDefaults()
        defaults.set(enabled, forKey: "menuBar.enabled")
        defaults.set(delay, forKey: "menuBar.collapseDelay")
        let surface = FakeSurface()
        let hider = MenuBarHider(defaults: defaults, surface: surface)
        hider.activate()
        return (hider, surface)
    }

    @Test func offByDefaultAndTheDefaultDelayIsTen() throws {
        let hider = MenuBarHider(defaults: try makeDefaults(), surface: FakeSurface())
        #expect(!hider.isEnabled)
        #expect(hider.collapseDelay == 10)
    }

    @Test func startsOpenThenCollapsesAfterTheDelay() async throws {
        let (hider, surface) = try hider()
        #expect(surface.collapsed == false)
        #expect(await eventually { surface.collapsed == true })
        #expect(hider.isCollapsed)
    }

    @Test func aLongDelayStaysOpen() async throws {
        let (hider, surface) = try hider(delay: 60)
        try await Task.sleep(for: .milliseconds(150))
        #expect(surface.collapsed == false)
        #expect(!hider.isCollapsed)
    }

    @Test func aClickExpandsACollapsedBarAndItCollapsesAgain() async throws {
        let (hider, surface) = try hider()
        #expect(await eventually { surface.collapsed == true })
        surface.onClick?()
        #expect(surface.collapsed == false)
        #expect(await eventually { surface.collapsed == true })
        #expect(hider.isCollapsed)
    }

    @Test func aClickCollapsesAnOpenBarAtOnce() throws {
        let (hider, surface) = try hider(delay: 60)
        surface.onClick?()
        #expect(surface.collapsed == true)
        #expect(hider.isCollapsed)
    }

    @Test func turningItOffRemovesTheItemsAndCancelsTheTimer() async throws {
        let (hider, surface) = try hider(delay: 0.05)
        hider.isEnabled = false
        #expect(surface.removals == 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(surface.collapsed == nil)
    }

    @Test func turningItOnInstallsOnceAndPlacesOurItemsFirst() throws {
        let (hider, surface) = try hider(enabled: false)
        var placed = 0
        hider.onPlaced = { placed += 1 }
        hider.isEnabled = true
        hider.isEnabled = true
        #expect(surface.installs == 1)
        #expect(placed == 1)
    }
}
