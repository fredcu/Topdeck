// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

/// The user's shortcuts as a list, in a popover on the Tools screen; choosing one runs it.
struct ShortcutsView: View {
    let shortcuts: ShortcutsFeature
    var done: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch shortcuts.status {
            case .loading:
                Text("Loading").deckText(.detail)
            case .unavailable:
                Text("Shortcuts unavailable").deckText(.detail)
            case .ready where shortcuts.visible.isEmpty:
                Button("Open Shortcuts") {
                    done()
                    shortcuts.openShortcutsApp()
                }
                .buttonStyle(.deck())
            case .ready:
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(shortcuts.visible, id: \.self) { name in
                            let running = shortcuts.running.contains(name)
                            DeckRow(
                                action: running
                                    ? nil
                                    : {
                                        done()
                                        shortcuts.run(name)
                                    }
                            ) {
                                Text(running ? "\(name) (running)" : name).deckText(.body).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(8)
        .frame(width: 240)
        .frame(maxHeight: 280)
        .fixedSize(horizontal: false, vertical: true)
    }
}
