// SPDX-License-Identifier: MIT
import KeyboardShortcuts
import SwiftUI
import TopdeckCore
import TopdeckSurface

/// The Tools space's body, as the board: the capture tiles and the captures kept lately on the left; on
/// the right Timer, Keep Awake, Sleep Screen, Pick Colour and Shortcuts, each opening its controls in a
/// popover. A part is left out when its feature is off.
public struct ToolsScreen: View {
    let capture: CaptureFeature?
    let timer: TimerFeature?
    let shortcuts: ShortcutsFeature?
    let sleepDisplays: () -> Void

    @Environment(\.deckAccent) private var accent
    @State private var open: Row?

    private enum Row: Hashable { case timer, awake, color, shortcuts }

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
        // The smallest decks take the shorter tiles and rows.
        GeometryReader { body in
            let compact = body.size.height < Self.compactBelow
            HStack(spacing: Deck.Metric.gap) {
                if let capture {
                    CaptureView(capture: capture, compact: compact)
                    Rectangle().fill(Deck.hairline).frame(width: 1)
                }
                rows(compact: compact)
                    .frame(width: capture == nil ? nil : (body.size.width < 560 ? 176 : 192))
            }
        }
    }

    /// The body height under which the full-size tiles would not fit.
    static let compactBelow: CGFloat = 275

    private func rows(compact: Bool) -> some View {
        VStack(spacing: 7) {
            if let timer {
                row(.timer, "Timer", .clock, Deck.Accent.now) {
                    timerPill(timer)
                } popover: {
                    TimerView(timer: timer, only: .clock).frame(width: 264, height: 168)
                }
                row(.awake, "Keep Awake", .coffee, Deck.Tint.yellow) {
                    awakePill(timer)
                } popover: {
                    TimerView(timer: timer, only: .awake).frame(width: 264, height: 98)
                }
            }
            plainRow("Sleep Screen", .moon, Deck.Accent.clipboard, pill: "Now", action: sleepDisplays)
            if let capture {
                row(.color, "Pick Colour", .colorPicker, accent) {
                    if let code = KeyboardShortcuts.getShortcut(for: .capture(.color)) {
                        Pill(text: "\(code)")
                    }
                } popover: {
                    ColorPopover(capture: capture) { open = nil }
                }
            }
            if let shortcuts {
                row(.shortcuts, "Shortcuts", .keyboard, Deck.secondary) {
                    if shortcuts.status == .ready { Pill(text: "\(shortcuts.visible.count)") }
                } popover: {
                    ShortcutsView(shortcuts: shortcuts) { open = nil }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Rows

    /// A row that opens a popover.
    private func row<P: View, Pop: View>(
        _ row: Row, _ title: String, _ icon: DeckIcon, _ tint: Color, @ViewBuilder pill: () -> P,
        @ViewBuilder popover: @escaping () -> Pop
    ) -> some View {
        Button {
            open = open == row ? nil : row
        } label: {
            ToolRowLabel(title: title, icon: icon, tint: tint, pill: pill)
        }
        .buttonStyle(.plain)
        .deckPopover(isPresented: Binding(get: { open == row }, set: { if !$0, open == row { open = nil } })) {
            popover().environment(\.deckAccent, accent)
        }
        .accessibilityLabel(title)
    }

    /// A row that acts at once.
    private func plainRow(_ title: String, _ icon: DeckIcon, _ tint: Color, pill: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            ToolRowLabel(title: title, icon: icon, tint: tint) { Pill(text: pill) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    @ViewBuilder private func timerPill(_ timer: TimerFeature) -> some View {
        if timer.mode == .stopwatch {
            let watch = timer.stopwatch
            if watch.isRunning || watch.elapsed(at: .now) > 0 {
                TimelineView(.periodic(from: .now, by: watch.isRunning ? 1 : 3600)) { context in
                    Pill(text: formatTime(watch.elapsed(at: context.date)))
                }
            }
        } else if let countdown = timer.countdown {
            TimelineView(.periodic(from: .now, by: countdown.isRunning ? 1 : 3600)) { context in
                Pill(text: formatTime(countdown.remaining(at: context.date)))
            }
        }
    }

    @ViewBuilder private func awakePill(_ timer: TimerFeature) -> some View {
        if let until = timer.awakeUntil {
            TimelineView(.everyMinute) { context in
                Pill(text: AwakeLabel.short(until: until, now: context.date))
            }
        }
    }
}

/// A row's face: an icon chip, the name and a small pill at the right, on a card.
private struct ToolRowLabel<P: View>: View {
    let title: String
    let icon: DeckIcon
    let tint: Color
    @ViewBuilder let pill: P

    var body: some View {
        HStack(spacing: 8) {
            DeckIconView(icon, size: 15)
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.tint(0.2)))
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Deck.text).lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 0)
            pill
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Deck.Radius.tile, style: .continuous).fill(Deck.card))
        .overlay(
            RoundedRectangle(cornerRadius: Deck.Radius.tile, style: .continuous).strokeBorder(
                Deck.hairline, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Deck.Radius.tile, style: .continuous))
    }
}

/// A small status at the right of a row: a running time, a count, a key.
private struct Pill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(Deck.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Capsule().fill(Deck.cardRaised))
    }
}
