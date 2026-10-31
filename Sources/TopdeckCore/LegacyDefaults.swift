// SPDX-License-Identifier: MIT
import Foundation

/// What earlier versions stored that this one no longer reads.
public enum LegacyDefaults {
    /// The autosave name of Topdeck's own menu bar item, whose place macOS remembers.
    public static let statusItemName = "net.icuai.topdeck.status"

    private static let hiderPrefix = "net.icuai.topdeck.menubar."

    private static func position(_ name: String) -> String { "NSStatusItem Preferred Position \(name)" }

    /// The menu bar hider is gone, and with it the two status items it made: nothing creates them any more.
    /// Its stored settings are left alone except where they would still show: macOS keeps a place for each
    /// named item, and Topdeck's own item was parked beside the hider's, well left of the usual corner. When
    /// the hider was on, that place is forgotten so the item goes back to the default one.
    public static func removeMenuBarHider(from defaults: UserDefaults = .standard) {
        if defaults.bool(forKey: "menuBar.enabled") { defaults.removeObject(forKey: position(statusItemName)) }
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("NSStatusItem") && key.contains(hiderPrefix) {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: "menuBar.enabled")
        defaults.removeObject(forKey: "menuBar.collapseDelay")
    }
}
