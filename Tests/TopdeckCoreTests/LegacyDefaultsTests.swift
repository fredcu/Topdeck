// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import TopdeckCore

struct LegacyDefaultsTests {
    private func suite() -> UserDefaults {
        let name = "LegacyDefaultsTests.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name)!
    }

    @Test func theHidersOwnPlacesAndSettingsAreForgotten() {
        let defaults = suite()
        defaults.set(true, forKey: "menuBar.enabled")
        defaults.set(30.0, forKey: "menuBar.collapseDelay")
        defaults.set(380.0, forKey: "NSStatusItem Preferred Position net.icuai.topdeck.menubar.expander")
        defaults.set(362.0, forKey: "NSStatusItem Preferred Position net.icuai.topdeck.menubar.separator")
        defaults.set(344.0, forKey: "NSStatusItem Preferred Position net.icuai.topdeck.status")
        defaults.set(true, forKey: "unrelated")
        LegacyDefaults.removeMenuBarHider(from: defaults)
        #expect(
            defaults.object(forKey: "menuBar.enabled") == nil && defaults.object(forKey: "menuBar.collapseDelay") == nil
        )
        #expect(defaults.object(forKey: "NSStatusItem Preferred Position net.icuai.topdeck.menubar.expander") == nil)
        #expect(defaults.object(forKey: "NSStatusItem Preferred Position net.icuai.topdeck.menubar.separator") == nil)
        #expect(
            defaults.object(forKey: "NSStatusItem Preferred Position net.icuai.topdeck.status") == nil,
            "back to the default corner")
        #expect(defaults.bool(forKey: "unrelated"))
    }

    @Test func aPlaceTheUserGaveTheItemWhileTheHiderWasOffStays() {
        let defaults = suite()
        defaults.set(120.0, forKey: "NSStatusItem Preferred Position net.icuai.topdeck.status")
        LegacyDefaults.removeMenuBarHider(from: defaults)
        #expect(defaults.double(forKey: "NSStatusItem Preferred Position net.icuai.topdeck.status") == 120)
    }
}
