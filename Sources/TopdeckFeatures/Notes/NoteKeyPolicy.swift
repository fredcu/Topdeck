// SPDX-License-Identifier: MIT
import Foundation

/// When a note's window may take the keyboard: only after the user asked for it, by clicking into it or by
/// opening it from the notch list or the Command Bar. Without that, closing the deck or the Command Bar
/// would hand the keyboard to whichever note AppKit picks next, and typing in another app would land in it.
struct NoteKeyPolicy {
    private(set) var canBecomeKey = false

    mutating func mouseDown() { canBecomeKey = true }

    mutating func present() { canBecomeKey = true }

    mutating func resign() { canBecomeKey = false }

    /// The editing action for ⌘X, ⌘C, ⌘V, ⌘A, ⌘Z and ⇧⌘Z. A non-activating panel in an app that isn't
    /// frontmost gets no menu key equivalents, so the window sends these itself.
    static func editingAction(for key: String, shift: Bool) -> Selector? {
        switch (key.lowercased(), shift) {
        case ("x", false): Selector(("cut:"))
        case ("c", false): Selector(("copy:"))
        case ("v", false): Selector(("paste:"))
        case ("a", false): Selector(("selectAll:"))
        case ("z", false): Selector(("undo:"))
        case ("z", true): Selector(("redo:"))
        default: nil
        }
    }
}
