// SPDX-License-Identifier: MIT
import KeyboardShortcuts
import SwiftUI
import TopdeckCore
import TopdeckSurface

/// The Tools space's body, as the board: the capture toolbars and the captures kept lately on the left; on
/// the right one list of Timer, Keep Awake, Sleep Screen, Pick Colour and Shortcuts, each opening its
/// controls in a popover. A part is left out when its feature is off.
public struct ToolsScreen: View {
    let capture: CaptureFeature?
    let timer: TimerFeature?
    let shortcuts: ShortcutsFeature?
    let sleepDisplays: () -> Void

    @Environment(\.deckAccent) private var accent
    @State private var open: Row?

    private enum Row: Hashable { case timer, awake, sleep, color, shortcuts }

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
        // The smallest decks take the shorter toolbars.
        GeometryReader { body in
            let compact = body.size.height < Self.compactBelow
            HStack(spacing: Deck.Metric.columnGap) {
                if let capture {
                    CaptureView(capture: capture, compact: compact)
                }
                list
                    .frame(width: capture == nil ? nil : (body.size.width < 560 ? 176 : 192))
            }
        }
    }

    /// The body height under which the full-size toolbars would not fit.
    static let compactBelow: CGFloat = 275

    private var rows: [Row] {
        (timer == nil ? [] : [.timer, .awake]) + [.sleep] + (capture == nil ? [] : [.color])
            + (shortcuts == nil ? [] : [.shortcuts])
    }

    /// The rows in one card, sharing its height, split by hairlines.
    private var list: some View {
        let shape = RoundedRectangle(cornerRadius: Deck.Radius.tile + 2, style: .continuous)
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element) { index, which in
                if index > 0 { Rectangle().fill(Deck.hairline).frame(height: 1) }
                rowView(which)
            }
        }
        .background(shape.fill(Deck.card))
        .overlay(shape.strokeBorder(Deck.hairline, lineWidth: 1))
        .clipShape(shape)
        .frame(maxHeight: .infinity)
    }

    // MARK: Rows

    @ViewBuilder private func rowView(_ which: Row) -> some View {
        switch which {
        case .timer:
            if let timer {
                row(.timer, "Timer", .clock, Deck.Accent.now) {
                    timerPill(timer)
                } popover: {
                    TimerView(timer: timer, only: .clock).frame(width: 264, height: 168)
                }
            }
        case .awake:
            if let timer {
                row(.awake, "Keep Awake", .coffee, Deck.Tint.yellow) {
                    awakePill(timer)
                } popover: {
                    TimerView(timer: timer, only: .awake).frame(width: 264, height: 98)
                }
            }
        case .sleep:
            Button(action: sleepDisplays) {
                ToolRowLabel(title: "Sleep Screen", icon: .moon, tint: Deck.Accent.clipboard) { Pill(text: "Now") }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sleep Screen")
        case .color:
            if let capture {
                row(.color, "Pick Colour", .colorPicker, accent) {
                    if let code = capture.colors.first, let color = ColorCode.rgb(code)?.color {
                        Pill {
                            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Deck.hairline)
                                )
                                .frame(width: 12, height: 12)
                        }
                    } else if let code = KeyboardShortcuts.getShortcut(for: .capture(.color)) {
                        Pill(text: "\(code)")
                    }
                } popover: {
                    ColorPopover(capture: capture) { open = nil }
                }
            }
        case .shortcuts:
            if let shortcuts {
                row(.shortcuts, "Shortcuts", .keyboard, Deck.secondary) {
                    if shortcuts.status == .ready { Pill(text: "\(shortcuts.visible.count)") }
                } popover: {
                    ShortcutsView(shortcuts: shortcuts) { open = nil }
                }
            }
        }
    }

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

    private func timerPill(_ timer: TimerFeature) -> some View {
        let running = TimerPill.face(for: timer, at: .now).live
        return TimelineView(.periodic(from: .now, by: running ? 1 : 3600)) { context in
            let face = TimerPill.face(for: timer, at: context.date)
            Pill(text: face.text, live: face.live)
        }
    }

    @ViewBuilder private func awakePill(_ timer: TimerFeature) -> some View {
        if let until = timer.awakeUntil {
            TimelineView(.everyMinute) { context in
                Pill(text: TimerPill.awake(until: until, now: context.date), live: true)
            }
        } else {
            Pill(text: TimerPill.awake(until: nil))
        }
    }
}

/// What the Timer and Keep Awake rows' pills say: a running clock in the accent, anything else plain.
@MainActor enum TimerPill {
    struct Face: Equatable {
        var text: String
        var live: Bool
    }

    /// The countdown's or stopwatch's time, live while it runs; "Start" with nothing under way. A countdown
    /// goes back to nothing when cancelled, so no set duration is kept to show.
    static func face(for timer: TimerFeature, at date: Date) -> Face {
        face(mode: timer.mode, countdown: timer.countdown, stopwatch: timer.stopwatch, at: date)
    }

    static func face(mode: TimerFeature.Mode, countdown: Countdown?, stopwatch: Stopwatch, at date: Date) -> Face {
        if mode == .stopwatch {
            let elapsed = stopwatch.elapsed(at: date)
            guard stopwatch.isRunning || elapsed > 0 else { return Face(text: "Start", live: false) }
            return Face(text: formatTime(elapsed, roundingUp: false), live: stopwatch.isRunning)
        }
        guard let countdown else { return Face(text: "Start", live: false) }
        return Face(text: formatTime(countdown.remaining(at: date)), live: countdown.isRunning)
    }

    /// The time left, or "On" with no end; "Off" when Keep Awake is not on.
    static func awake(until: Date?, now: Date = .now) -> String {
        until.map { AwakeLabel.short(until: $0, now: now) } ?? "Off"
    }
}

/// A row's face: a line icon, the name and a pill at the trailing edge.
private struct ToolRowLabel<P: View>: View {
    let title: String
    let icon: DeckIcon
    let tint: Color
    @ViewBuilder let pill: P

    var body: some View {
        // Tight enough for "Sleep Screen" and its pill in the 176-wide column.
        HStack(spacing: 8) {
            DeckIconView(icon, size: 18).foregroundStyle(tint)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Deck.text).lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(maxWidth: .infinity, alignment: .leading)
            pill
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

/// A capsule at the right of a row: a running time, a state, a count, a key, a swatch. `live` is a running
/// one, in the accent.
private struct Pill<Content: View>: View {
    var live = false
    @ViewBuilder let content: Content
    @Environment(\.deckAccent) private var accent

    var body: some View {
        content
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(live ? accent : Deck.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(live ? accent.tint(0.18) : Deck.cardRaised))
    }
}

extension Pill where Content == Text {
    fileprivate init(text: String, live: Bool = false) {
        self.init(live: live) { Text(text) }
    }
}
