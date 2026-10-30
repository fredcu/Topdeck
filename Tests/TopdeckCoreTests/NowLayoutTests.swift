// SPDX-License-Identifier: MIT
import Testing

@testable import TopdeckCore

struct NowLayoutTests {
    private func layout(
        media: Bool = false, agent: Bool = false, event: Bool = false, task: Bool = false, timer: Bool = false,
        awake: Bool = false
    ) -> NowLayout {
        NowLayout(media: media, agent: agent, event: event, task: task, timer: timer, awake: awake)
    }

    @Test func withNothingToShowNowIsTheDateAndClock() {
        #expect(layout().isEmpty && layout().rows.isEmpty)
    }

    @Test func everythingFillsTheBoardsTwoByTwo() {
        let all = layout(media: true, agent: true, event: true, task: true, timer: true, awake: true)
        #expect(all.rows == [[.media, .agent], [.event, .timers]])
    }

    @Test func anEmptySlotClosesUp() {
        #expect(layout(media: true, timer: true).rows == [[.media, .timers]])
        #expect(layout(agent: true, task: true, awake: true).rows == [[.agent, .event], [.timers]])
        #expect(layout(media: true).rows == [[.media]], "a lone card fills the width")
    }

    @Test func aTaskAloneOrAnEventAloneStillMakesTheCard() {
        #expect(layout(task: true).rows == [[.event]])
        #expect(layout(event: true).rows == [[.event]])
        #expect(layout(timer: true, awake: true).rows == [[.timers]], "both timers share one card")
    }
}
