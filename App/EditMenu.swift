// SPDX-License-Identifier: MIT
import AppKit

extension NSMenu {
    /// An accessory app shows no menu bar, but AppKit still finds ⌘C and its like through the main menu,
    /// so without this no text field in the app can copy, paste, select all, or undo.
    static func hiddenEditMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let menu = NSMenu()
        menu.addItem(NSMenuItem())  // the first item is always the application menu
        let item = NSMenuItem()
        item.submenu = edit
        menu.addItem(item)
        return menu
    }
}
