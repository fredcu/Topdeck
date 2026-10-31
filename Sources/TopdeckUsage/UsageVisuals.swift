// SPDX-License-Identifier: MIT
import SwiftUI

/// Refresh, spinning while anything refreshes.
struct RefreshButton: View {
    let spinning: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let spins = spinning && !reduceMotion
        let spin: Animation = spins ? .linear(duration: 1).repeatForever(autoreverses: false) : .default
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .imageScale(.medium)
                .fontWeight(.semibold)
                .rotationEffect(.degrees(spins ? 360 : 0))
                .animation(spin, value: spinning)
        }
        .buttonStyle(.deckIcon())
        .help("Refresh now")
        .accessibilityLabel("Refresh")
    }
}
