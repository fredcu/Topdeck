// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import TopdeckFeatures

@MainActor
struct ClipboardViewTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func ageIsAWordOrTwo() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 12))!
        func age(_ seconds: TimeInterval) -> String {
            ClipboardView.age(of: noon.addingTimeInterval(-seconds), at: noon, calendar: calendar)
        }
        #expect(age(30) == "Now")
        #expect(age(120) == "2m")
        #expect(age(3 * 3600) == "3h")
        #expect(age(15 * 3600) == "Yesterday", "before midnight is yesterday, not 15h")
        #expect(age(3 * 86400) == noon.addingTimeInterval(-3 * 86400).formatted(.dateTime.month(.abbreviated).day()))
    }

    @Test func aLinkNamesItsSite() {
        let link = ClipItem(kind: .link, text: "https://www.github.com/fredcu/Topdeck", copied: now)
        #expect(ClipboardView.host(of: link) == "github.com")
        #expect(ClipboardView.host(of: ClipItem(kind: .text, text: "https://github.com", copied: now)) == nil)
    }

    @Test func aRowSaysWhereAndHowLongAgo() {
        var item = ClipItem(kind: .text, text: "hello", copied: now.addingTimeInterval(-120))
        #expect(ClipboardView.subtitle(of: item, at: now) == "2m")
        item.source = "Safari"
        #expect(ClipboardView.subtitle(of: item, at: now) == "Safari, 2m")
        #expect(ClipboardView.origin(of: item, at: now) == "Safari, 2m ago")
    }

    @Test func thePreviewSaysWhatItShows() {
        let picture = ClipItem(kind: .image, text: "Image 1440 × 900", copied: now)
        #expect(ClipboardView.facts(of: picture) == "1440 × 900, PNG")
        #expect(ClipboardView.facts(of: ClipItem(kind: .text, text: "hello", copied: now)) == "5 characters")
    }
}
