// SPDX-License-Identifier: MIT
import KeyboardShortcuts
import SwiftUI

extension WindowSwitcher {
    /// The sections of the Window Switcher page in Settings, shown while it's on.
    public var settingsView: some View { WindowSwitcherSettings(switcher: self) }
}

private struct WindowSwitcherSettings: View {
    let switcher: WindowSwitcher

    var body: some View {
        Group {
            if !switcher.isTrusted {
                Section {
                    LabeledContent("Accessibility") {
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(.privacySettings("Privacy_Accessibility"))
                        }
                    }
                }
            }
            if !switcher.canCapture {
                Section {
                    LabeledContent("Screen Recording") {
                        Button("Open Privacy Settings", action: switcher.requestCapture)
                    }
                }
            }
            Section {
                KeyboardShortcuts.Recorder("Shortcut", name: .windowSwitcher)
            }
        }
        .onAppear(perform: switcher.refreshAccess)
    }
}
