// SPDX-License-Identifier: MIT
import KeyboardShortcuts
import SwiftUI

extension CommandBar {
    /// The sections of the Command Bar page in Settings, shown while it's on.
    public var settingsView: some View {
        Section { KeyboardShortcuts.Recorder("Open the command bar", name: .commandBar) }
    }
}
