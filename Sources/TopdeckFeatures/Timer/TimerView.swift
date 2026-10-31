// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

/// What the Keep Awake card says about how long is left.
enum AwakeLabel {
    /// "1:12", "42m" or "On": the short form for a pill.
    static func short(until: Date, now: Date = .now) -> String {
        if until == .distantFuture { return "On" }
        let minutes = max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
        return minutes >= 60 ? String(format: "%d:%02d", minutes / 60, minutes % 60) : "\(minutes)m"
    }

    /// "1:12 left" with an hour or more to go, "42 min left" under it, "On" until it is turned off.
    static func text(until: Date, now: Date = .now) -> String {
        if until == .distantFuture { return "On" }
        let minutes = max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
        return minutes >= 60 ? String(format: "%d:%02d left", minutes / 60, minutes % 60) : "\(minutes) min left"
    }
}

/// The timer and Keep Awake cards: a countdown or a stopwatch, and how long to keep the Mac awake. The
/// Tools screen shows one of them in a popover (`only`); the Timer's own view shows both, one above the other.
struct TimerView: View {
    enum Part { case clock, awake }

    let timer: TimerFeature
    var compact = false
    var only: Part?

    var body: some View {
        VStack(spacing: Deck.Metric.gap) {
            if only != .awake { clockCard }
            if only != .clock { awakeCard }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var cardPadding: CGFloat { compact ? 12 : Deck.Metric.cardPadding }

    // MARK: Timer and stopwatch

    private var clockCard: some View {
        DeckCard(padding: cardPadding) {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text(timer.mode == .stopwatch ? "Stopwatch" : "Timer").deckText(.caption)
                    Spacer(minLength: 0)
                    if timer.mode != .stopwatch, timer.countdown != nil {
                        DeckIconButton(.close, label: "Cancel timer", action: timer.cancel)
                    }
                    Button {
                        timer.mode = timer.mode == .stopwatch ? .countdown : .stopwatch
                    } label: {
                        DeckIconView(.clock, size: 13)
                    }
                    .buttonStyle(.deckIcon(on: timer.mode == .stopwatch))
                    .frame(width: 26, height: 26)
                    .help(timer.mode == .stopwatch ? "Timer" : "Stopwatch")
                    .accessibilityLabel(timer.mode == .stopwatch ? "Timer" : "Stopwatch")
                }
                .frame(height: 26)
                Spacer(minLength: 0)
                if timer.mode == .stopwatch { stopwatch } else { countdown }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    private var clockStyle: DeckTextStyle { compact ? .metric : .timer }

    /// The clock in the middle of the card and its buttons along the bottom; the presets when idle.
    @ViewBuilder private var countdown: some View {
        if let countdown = timer.countdown {
            // Redraws once a second, and only while running on screen.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = countdown.remaining(at: context.date)
                RollingTime(left, countsDown: true)
                    .deckText(clockStyle)
                    .opacity(countdown.isRunning ? 1 : 0.5)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Timer, \(formatTime(left)) left")
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                Button(countdown.isRunning ? "Pause" : "Resume") {
                    countdown.isRunning ? timer.pause() : timer.resume()
                }
                .buttonStyle(.deck(.primary, fill: true))
                Button("+1", action: timer.addMinute).buttonStyle(.deck())
            }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(TimerFeature.presets, id: \.self) { seconds in
                    Button(Self.presetTitle(seconds)) { timer.start(seconds) }
                        .buttonStyle(.deckPill())
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Start a \(formatTime(seconds)) timer")
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// "5m", "1h".
    static func presetTitle(_ seconds: TimeInterval) -> String {
        seconds < 3600 ? "\(Int(seconds / 60))m" : "\(Int(seconds / 3600))h"
    }

    @ViewBuilder private var stopwatch: some View {
        let watch = timer.stopwatch
        VStack(spacing: 2) {
            // Tenths of a second need ten redraws a second, only while running on screen.
            TimelineView(.periodic(from: .now, by: watch.isRunning ? 0.1 : 3600)) { context in
                RollingTime(watch.elapsed(at: context.date), tenths: true).deckText(clockStyle)
            }
            if let last = watch.laps.indices.last {
                let split = watch.laps[last] - (last > 0 ? watch.laps[last - 1] : 0)
                Text("Lap \(last + 1)  \(formatTime(split, tenths: true))").deckText(.caption).lineLimit(1)
            }
        }
        .frame(maxHeight: .infinity)
        HStack(spacing: 8) {
            Button(watch.isRunning ? "Pause" : "Start") { timer.toggleStopwatch() }
                .buttonStyle(.deck(.primary))
                .frame(maxWidth: .infinity)
            if watch.isRunning {
                Button("Lap") { timer.lap() }.buttonStyle(.deck())
            } else {
                Button("Reset", action: timer.resetStopwatch)
                    .buttonStyle(.deck())
                    .disabled(watch.elapsed(at: .now) == 0)
            }
        }
    }

    // MARK: Keep awake

    private var awakeCard: some View {
        DeckCard(padding: cardPadding) {
            VStack(spacing: Deck.Metric.gap) {
                HStack {
                    Text("Keep Awake").deckText(.body)
                    Spacer(minLength: 0)
                    if let until = timer.awakeUntil {
                        TimelineView(.everyMinute) { context in
                            Text(AwakeLabel.text(until: until, now: context.date)).deckText(.detail)
                        }
                    }
                    options
                }
                .frame(height: 26)
                HStack(spacing: 6) {
                    ForEach(TimerFeature.awakePresets.prefix(3), id: \.self) { seconds in
                        Button(Self.presetTitle(seconds)) { timer.keepAwake(for: seconds) }
                            .buttonStyle(.deckPill())
                            .accessibilityLabel("Keep awake for \(formatTime(seconds))")
                    }
                    Button("\u{221E}") { timer.keepAwake(for: nil) }
                        .buttonStyle(.deckPill(on: timer.awakeUntil == .distantFuture))
                        .help("Until you turn it off")
                        .accessibilityLabel("Keep awake until you turn it off")
                    Spacer(minLength: 0)
                    if timer.keepsAwake {
                        DeckChip("Off", selected: true, action: timer.allowSleep)
                    }
                }
            }
        }
    }

    /// Keeping the display on too, and keeping awake until a clock time.
    private var options: some View {
        Menu {
            Toggle("Keep screen on", isOn: Binding(get: { timer.keepScreenOn }, set: { timer.keepScreenOn = $0 }))
            Divider()
            ForEach(Self.nextHours(), id: \.self) { time in
                Button("Until \(time.formatted(date: .omitted, time: .shortened))") {
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                    timer.keepAwake(.at(hour: parts.hour ?? 0, minute: parts.minute ?? 0))
                }
            }
            if let until = timer.awakeUntil, until != .distantFuture {
                Divider()
                Button("Add 30 Minutes") { timer.extendAwake() }
            }
        } label: {
            DeckIconView(.chevronDown, size: 12)
                .foregroundStyle(Deck.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More ways to keep awake")
    }

    /// The next three whole hours from `now`.
    static func nextHours(now: Date = .now, calendar: Calendar = .current) -> [Date] {
        guard
            let first = calendar.nextDate(
                after: now, matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime)
        else { return [] }
        return (0..<3).compactMap { calendar.date(byAdding: .hour, value: $0, to: first) }
    }
}
