// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import TopdeckFeatures

struct PlanEntryTests {
    @Test func aLineWithATimeIsAnEvent() {
        #expect(PlanEntry.route("Lunch tomorrow 1pm") == .event)
        #expect(PlanEntry.route("Dinner with Sam tomorrow 7:30pm for 2h") == .event)
    }

    @Test func everythingElseIsATask() {
        #expect(PlanEntry.route("Renew domain") == .task, "no time")
        #expect(PlanEntry.route("Renew domain tomorrow") == .task, "a day is not a time")
        #expect(PlanEntry.route("Pay rent fri 9am !!") == .task, "priority marks")
        #expect(PlanEntry.route("Call Sam tomorrow 5pm #Work") == .task, "a list")
        #expect(PlanEntry.route("Water plants every week 8am") == .task, "a repeat")
    }
}

struct EventDetailTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let zoom = MeetingLink(URL(string: "https://zoom.us/j/1")!)

    private func event(in minutes: Double, meeting: Bool = false, location: String? = nil) -> DayEvent {
        let start = now + minutes * 60
        return DayEvent(
            id: "e", title: "E", start: start, end: start + 1800, meeting: meeting ? zoom : nil, location: location)
    }

    @Test func whatStartsWithinTheHourSaysHowSoon() {
        #expect(EventDetail.text(for: event(in: 28), now: now, isToday: true) == "in 28 minutes")
        #expect(EventDetail.text(for: event(in: 0.5), now: now, isToday: true) == "in 1 minute")
        #expect(EventDetail.text(for: event(in: 28, location: "Bondi"), now: now, isToday: true) == "in 28 minutes")
    }

    @Test func otherwiseItSaysWhere() {
        #expect(EventDetail.text(for: event(in: 120, location: "Bondi"), now: now, isToday: true) == "Bondi")
        #expect(EventDetail.text(for: event(in: 20, location: "Bondi"), now: now, isToday: false) == "Bondi")
        #expect(EventDetail.text(for: event(in: -10), now: now, isToday: true) == nil, "already started")
    }

    @Test func onlyAMeetingAboutToStartIsSignal() {
        #expect(EventDetail.isAboutToStart(event(in: 28, meeting: true), now: now, isToday: true))
        #expect(!EventDetail.isAboutToStart(event(in: 28), now: now, isToday: true), "no call to join")
        #expect(!EventDetail.isAboutToStart(event(in: 90, meeting: true), now: now, isToday: true), "not yet")
        #expect(!EventDetail.isAboutToStart(event(in: 10, meeting: true), now: now, isToday: false))
    }
}

struct PlanLabelTests {
    private let calendar = Calendar(identifier: .gregorian)

    @Test func dueDatesAreShort() throws {
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 12)))
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now)! }
        #expect(PlanDue.text(for: day(0), hasTime: false, now: now, calendar: calendar) == "Today")
        #expect(PlanDue.text(for: day(1), hasTime: false, now: now, calendar: calendar) == "Tomorrow")
        #expect(PlanDue.text(for: day(-1), hasTime: false, now: now, calendar: calendar) == "Yesterday")
        #expect(
            PlanDue.text(for: day(3), hasTime: false, now: now, calendar: calendar)
                == day(3).formatted(.dateTime.weekday(.abbreviated)))
        #expect(
            PlanDue.text(for: day(30), hasTime: false, now: now, calendar: calendar)
                == day(30).formatted(.dateTime.day().month(.abbreviated)))
    }

    @Test func keepAwakeSaysHowLongIsLeft() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(AwakeLabel.text(until: now + 72 * 60, now: now) == "1:12 left")
        #expect(AwakeLabel.text(until: now + 42 * 60 - 20, now: now) == "42 min left")
        #expect(AwakeLabel.text(until: now + 10, now: now) == "1 min left")
        #expect(AwakeLabel.text(until: .distantFuture, now: now) == "On")
    }

    @Test @MainActor func presetsAreShort() {
        #expect(TimerView.presetTitle(300) == "5m" && TimerView.presetTitle(3600) == "1h")
        #expect(TimerView.nextHours(now: Date(timeIntervalSince1970: 1_790_000_000)).count == 3)
    }
}
