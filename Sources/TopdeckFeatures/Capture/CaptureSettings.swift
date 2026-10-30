// SPDX-License-Identifier: MIT
import KeyboardShortcuts
import SwiftUI

extension CaptureFeature {
    /// The rows of the Capture page in Settings.
    public var settingsView: some View { CaptureSettings() }
}

private struct CaptureSettings: View {
    var body: some View {
        ForEach(CaptureFeature.Tool.allCases) { tool in
            KeyboardShortcuts.Recorder(tool.title, name: .capture(tool))
        }
    }
}
