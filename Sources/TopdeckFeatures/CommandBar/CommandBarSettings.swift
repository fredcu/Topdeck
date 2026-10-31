// SPDX-License-Identifier: MIT
import KeyboardShortcuts
import SwiftUI

extension CommandBar {
    /// The sections of the Command Bar page in Settings, shown while it's on.
    public var settingsView: some View {
        Section { KeyboardShortcuts.Recorder("Open the command bar", name: .commandBar) }
    }
}

extension CommandBar {
    /// Its shortcut as keys, such as "\u{2325}Space", where one is set.
    public var shortcutText: String? { KeyboardShortcuts.getShortcut(for: .commandBar)?.description }
}
