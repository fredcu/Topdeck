// SPDX-License-Identifier: MIT
import Testing

@testable import TopdeckCore

struct MusicBarsTests {
    @Test func fourBarsOfThreeWithTwoBetweenAreEighteenWide() {
        #expect(MusicBars.count == 4 && MusicBars.width == 18)
        #expect(MusicBars.maxHeight == 14)
    }

    @Test func everyHeightStaysBetweenTheShortestAndTheTallest() {
        for step in 0..<4000 {
            for height in MusicBars.heights(at: Double(step) * 0.05) {
                #expect(height >= MusicBars.minHeight && height <= MusicBars.maxHeight)
            }
        }
    }

    @Test func theBarsDoNotMoveTogetherAndDoMoveOverTime() {
        let now = MusicBars.heights(at: 12.3)
        #expect(Set(now.map { ($0 * 100).rounded() }).count > 1, "four different heights")
        #expect(now != MusicBars.heights(at: 12.35), "one frame later (20 a second) is a different picture")
        #expect(MusicBars.heights(at: 12.3) == now, "the same moment is the same picture")
    }

    @Test func eachBarUsesTheWholeRangeOverTime() {
        for bar in 0..<MusicBars.count {
            let heights = (0..<6000).map { MusicBars.height(bar: bar, at: Double($0) * 0.01) }
            #expect(heights.min()! < 5 && heights.max()! > 12, "bar \(bar) sweeps low to high")
        }
    }

    @Test func pausedIsLowAndReduceMotionIsStillInTheMiddle() {
        #expect(MusicBars.resting.count == 4 && MusicBars.resting.allSatisfy { $0 <= 6 && $0 >= MusicBars.minHeight })
        #expect(MusicBars.still.count == 4 && MusicBars.still.allSatisfy { $0 > 6 && $0 <= MusicBars.maxHeight })
    }

    @Test func onlyPlayingWithMotionOnNeedsATimeline() {
        #expect(MusicBars.animates(playing: true, reduceMotion: false))
        #expect(!MusicBars.animates(playing: false, reduceMotion: false), "paused: nothing wakes up")
        #expect(!MusicBars.animates(playing: true, reduceMotion: true), "Reduce Motion: still")
        #expect(!MusicBars.animates(playing: false, reduceMotion: true))
    }

    @Test func aBarThatDoesNotExistIsTheShortest() {
        #expect(MusicBars.height(bar: 9, at: 1) == MusicBars.minHeight)
    }
}
