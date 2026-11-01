// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import Testing
import TopdeckCore

@testable import TopdeckFeatures

@MainActor
struct CalendarChoiceTests {
    private static func calendar(
        _ id: String, _ title: String, in source: String, _ kind: CalendarInfo.SourceKind,
        color: RGB? = nil
    ) -> CalendarInfo {
        CalendarInfo(id: id, title: title, color: color, sourceTitle: source, sourceKind: kind)
    }

    private static let calendars = [
        calendar(
            "holidays", "UK Holidays", in: "Subscribed Calendars", .subscribed,
            color: RGB(red: 0.2, green: 0.5, blue: 0.9)),
        calendar("work", "Work", in: "Google", .calDAV, color: RGB(red: 0.9, green: 0.3, blue: 0.2)),
        calendar("home", "Home", in: "iCloud", .iCloud, color: RGB(red: 0.2, green: 0.7, blue: 0.4)),
        calendar("birthdays", "Birthdays", in: "Other", .birthdays),
        calendar("family", "family", in: "iCloud", .iCloud, color: RGB(red: 0.9, green: 0.6, blue: 0.1)),
        calendar("local", "On My Mac", in: "On My Mac", .local),
    ]

    @Test func hiddenCalendarsAreLeftOutAndNewOnesShow() {
        #expect(
            CalendarChoice.visibleIDs(Self.calendars, hidden: []).count == Self.calendars.count,
            "nothing hidden at first")
        let visible = CalendarChoice.visibleIDs(Self.calendars, hidden: ["holidays", "birthdays", "gone"])
        #expect(visible == ["work", "home", "family", "local"])
        let added = Self.calendars + [Self.calendar("new", "New", in: "iCloud", .iCloud)]
        #expect(CalendarChoice.visibleIDs(added, hidden: ["holidays"]).contains("new"), "a calendar added later shows")
    }

    @Test func withEveryCalendarHiddenNothingIsRead() {
        let all = Set(Self.calendars.map(\.id))
        #expect(CalendarChoice.visibleIDs(Self.calendars, hidden: all).isEmpty)
        #expect(CalendarChoice.visibleIDs([], hidden: []).isEmpty)
    }

    @Test func accountsAreOrderedByKindAndCalendarsByTitle() {
        let groups = CalendarChoice.groups(Self.calendars)
        #expect(groups.map(\.title) == ["On My Mac", "iCloud", "Google", "Subscribed Calendars", "Other"])
        #expect(groups[1].calendars.map(\.title) == ["family", "Home"], "by title, ignoring case")
        #expect(CalendarChoice.groups(Self.calendars.reversed()) == groups, "the same whatever order EventKit gives")
    }

    @Test func twoAccountsWithOneNameStayApart() {
        let calendars = [
            CalendarInfo(id: "a", title: "A", sourceID: "s1", sourceTitle: "Google", sourceKind: .calDAV),
            CalendarInfo(id: "b", title: "B", sourceID: "s2", sourceTitle: "Google", sourceKind: .calDAV),
        ]
        #expect(CalendarChoice.groups(calendars).map(\.calendars.count) == [1, 1])
    }

    @Test func theChoiceIsKept() {
        let defaults = UserDefaults(suiteName: "CalendarChoice.\(UUID())")!
        let store = EventStore()
        #expect(CalendarFeature(eventStore: store, defaults: defaults).hiddenCalendars.isEmpty)
        let calendar = CalendarFeature(eventStore: store, defaults: defaults)
        calendar.setVisible("holidays", false)
        calendar.setVisible("work", false)
        calendar.setVisible("work", true)
        let again = CalendarFeature(eventStore: store, defaults: defaults)
        #expect(again.hiddenCalendars == ["holidays"])
        #expect(!again.isVisible("holidays") && again.isVisible("work"))
    }

    /// The list as Settings shows it, in a grouped form. With SNAPSHOT_DIR set, also writes a PNG.
    @Test func theListDraws() throws {
        let hidden: Set<String> = ["holidays", "birthdays"]
        let list = Form {
            CalendarChoiceView(
                groups: CalendarChoice.groups(Self.calendars), isVisible: { !hidden.contains($0) },
                setVisible: { _, _ in })
        }
        .formStyle(.grouped)
        let host = NSHostingView(rootView: list.frame(width: 480, height: 580))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 580), styleMask: .borderless, backing: .buffered,
            defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        if let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(filePath: directory).appending(path: "calendars.png"))
        }
    }
}
