// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

/// The Shortcuts button on the Tools screen: a menu of the user's shortcuts; choosing one runs it.
struct ShortcutsView: View {
    let shortcuts: ShortcutsFeature

    var body: some View {
        Menu {
            switch shortcuts.status {
            case .loading:
                Text("Loading")
            case .unavailable:
                Text("Shortcuts unavailable")
            case .ready where shortcuts.visible.isEmpty:
                Button("Open Shortcuts", action: shortcuts.openShortcutsApp)
            case .ready:
                ForEach(shortcuts.visible, id: \.self) { name in
                    let running = shortcuts.running.contains(name)
                    Button(running ? "\(name) (running)" : name) { shortcuts.run(name) }
                        .disabled(running)
                }
            }
        } label: {
            HStack(spacing: 6) {
                DeckIconView(.stack, size: 13)
                Text("Shortcuts")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Deck.text)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: Deck.Metric.buttonHeight)
            .background(RoundedRectangle(cornerRadius: Deck.Radius.control, style: .continuous).fill(Deck.control))
            .contentShape(RoundedRectangle(cornerRadius: Deck.Radius.control, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Shortcuts")
    }
}
