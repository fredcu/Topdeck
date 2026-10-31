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

    @Test @MainActor func presetsAreShort() {
        #expect(TimerView.presetTitle(300) == "5m" && TimerView.presetTitle(3600) == "1h")
        #expect(TimerView.nextHours(now: Date(timeIntervalSince1970: 1_790_000_000)).count == 3)
    }
}
