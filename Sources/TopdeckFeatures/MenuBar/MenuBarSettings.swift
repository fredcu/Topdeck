// SPDX-License-Identifier: MIT
import SwiftUI

extension MenuBarHider {
    /// Its settings, shown under the switch on its Settings page.
    public var settingsView: some View { MenuBarSettings(hider: self) }
}

private struct MenuBarSettings: View {
    @Bindable var hider: MenuBarHider

    var body: some View {
        Section {
            Picker("Hide again after", selection: $hider.collapseDelay) {
                ForEach(MenuBarLayout.delays, id: \.self) { seconds in
                    Text("\(Int(seconds)) seconds").tag(seconds)
                }
            }
        }
    }
}
