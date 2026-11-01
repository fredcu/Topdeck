// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import TopdeckFeatures

struct ToolsLabelTests {
    @Test func keepAwakeSaysHowLongIsLeft() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(AwakeLabel.text(until: now + 72 * 60, now: now) == "1:12 left")
        #expect(AwakeLabel.text(until: now + 42 * 60 - 20, now: now) == "42 min left")
        #expect(AwakeLabel.text(until: now + 10, now: now) == "1 min left")
        #expect(AwakeLabel.text(until: .distantFuture, now: now) == "On")
    }

    @Test func theKeepAwakePillIsShort() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(AwakeLabel.short(until: now + 72 * 60, now: now) == "1:12")
        #expect(AwakeLabel.short(until: now + 3600, now: now) == "1:00")
        #expect(AwakeLabel.short(until: now + 42 * 60 - 20, now: now) == "42m")
        #expect(AwakeLabel.short(until: .distantFuture, now: now) == "On")
    }

    @Test @MainActor func theTimerPillIsLiveOnlyWhileRunning() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let none = TimerPill.face(mode: .countdown, countdown: nil, stopwatch: Stopwatch(), at: now)
        #expect(none == TimerPill.Face(text: "Start", live: false))
        let running = Countdown(total: 1500, endsAt: now + 1498, remaining: 1500)
        #expect(
            TimerPill.face(mode: .countdown, countdown: running, stopwatch: Stopwatch(), at: now)
                == TimerPill.Face(text: "24:58", live: true))
        let paused = Countdown(total: 1500, endsAt: nil, remaining: 600)
        #expect(
            TimerPill.face(mode: .countdown, countdown: paused, stopwatch: Stopwatch(), at: now)
                == TimerPill.Face(text: "10:00", live: false))
        var watch = Stopwatch()
        #expect(TimerPill.face(mode: .stopwatch, countdown: nil, stopwatch: watch, at: now).text == "Start")
        watch.start(at: now)
        #expect(
            TimerPill.face(mode: .stopwatch, countdown: nil, stopwatch: watch, at: now + 65)
                == TimerPill.Face(text: "1:05", live: true))
        watch.pause(at: now + 65)
        #expect(
            TimerPill.face(mode: .stopwatch, countdown: nil, stopwatch: watch, at: now + 90)
                == TimerPill.Face(text: "1:05", live: false))
    }

    @Test @MainActor func theKeepAwakePillSaysOffWhenOff() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(TimerPill.awake(until: nil, now: now) == "Off")
        #expect(TimerPill.awake(until: now + 42 * 60, now: now) == "42m")
    }

    @Test @MainActor func recentCapturesFillRowsThatFit() {
        let full = RecentCaptures.grid(in: CGSize(width: 466, height: 194), compact: false)
        #expect(full.columns == 4 && full.rows == 2)
        #expect(abs(full.thumb.width / full.thumb.height - 1.6) < 0.001)
        let one = RecentCaptures.grid(in: CGSize(width: 466, height: 150), compact: false)
        #expect(one.rows == 1)
        let small = RecentCaptures.grid(in: CGSize(width: 386, height: 120), compact: true)
        #expect(small.columns == 3 && small.rows == 1)
        #expect(RecentCaptures.grid(in: CGSize(width: 386, height: 10), compact: true).rows == 1, "never none")
    }

    @Test @MainActor func presetsAreShort() {
        #expect(TimerView.presetTitle(300) == "5m" && TimerView.presetTitle(3600) == "1h")
        #expect(TimerView.nextHours(now: Date(timeIntervalSince1970: 1_790_000_000)).count == 3)
    }
}
