// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckCore
import TopdeckSurface

/// The Tools space's body: the capture tools and recent colors, with Shortcuts and Sleep Displays
/// under them, beside the timer and Keep Awake. A part is left out when its feature is off.
public struct ToolsScreen: View {
    let capture: CaptureFeature?
    let timer: TimerFeature?
    let shortcuts: ShortcutsFeature?
    let sleepDisplays: () -> Void

    public init(
        capture: CaptureFeature?, timer: TimerFeature?, shortcuts: ShortcutsFeature?,
        sleepDisplays: @escaping () -> Void
    ) {
        self.capture = capture
        self.timer = timer
        self.shortcuts = shortcuts
        self.sleepDisplays = sleepDisplays
    }

    public var body: some View {
        // The smallest decks take the shorter tiles and cards.
        GeometryReader { body in
            screen(compact: body.size.height < Self.compactBelow)
        }
    }

    /// The body height under which the full-size tiles and cards would not fit.
    static let compactBelow: CGFloat = 275

    private func screen(compact: Bool) -> some View {
        DeckWeightedRow(timer == nil ? [1] : [1.2, 1]) {
            left(compact: compact)
            if let timer { TimerView(timer: timer, compact: compact) }
        }
    }

    private func left(compact: Bool) -> some View {
        VStack(spacing: Deck.Metric.gap) {
            if let capture { CaptureView(capture: capture, compact: compact) }
            HStack(spacing: Deck.Metric.gap) {
                if let shortcuts { ShortcutsView(shortcuts: shortcuts) }
                Button(action: sleepDisplays) {
                    HStack(spacing: 6) {
                        DeckIconView(.moon, size: 13)
                        Text("Sleep Displays")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.deck())
            }
            .frame(maxHeight: capture == nil ? .infinity : nil, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
