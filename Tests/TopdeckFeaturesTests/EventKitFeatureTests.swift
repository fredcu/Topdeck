// SPDX-License-Identifier: MIT
import EventKit
import Foundation
import Testing
import TopdeckCore

@testable import TopdeckFeatures

@MainActor
struct EventKitFeatureTests {
    private let defaults = UserDefaults(suiteName: "EventKitTests.\(UUID().uuidString)")!
    private let noon = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func theAgendaListsAllDayEventsFirstThenByTime() {
        let events = [
            DayEvent(id: "c", title: "Lunch", start: noon, end: noon + 3600),
            DayEvent(id: "a", title: "Holiday", start: noon - 43_200, end: noon + 43_200, isAllDay: true),
            DayEvent(id: "b", title: "Standup", start: noon - 7200, end: noon - 6300),
        ]
        #expect(events.sorted(by: DayEvent.agendaOrder).map(\.title) == ["Holiday", "Standup", "Lunch"])
    }

    @Test func withoutAccessNothingIsReadOrWatched() {
        // Test runners never grant EventKit access, so this is the not-yet-allowed path.
        let store = EventStore()
        let calendar = CalendarFeature(eventStore: store, defaults: defaults)
        calendar.phase = .foreground
        #expect(calendar.access != .granted && calendar.events.isEmpty && !calendar.isObserving)
        #expect(calendar.rangeEvents.isEmpty)
    }

    @Test func onlyYourOwnEventsCanBeChangedFromTheNotch() {
        let store = EventStore().store
        let event = EKEvent(eventStore: store)
        event.title = "Lunch"
        event.startDate = noon
        event.endDate = noon + 3600
        #expect(DayEvent(event).id == DayEvent.id(for: event), "a change finds the event by the agenda's id")
        #expect(!DayEvent(event).isEditable, "no calendar to change it in")
        event.calendar = EKCalendar(for: .event, eventStore: store)
        #expect(DayEvent(event).isEditable, "yours, with nobody invited")

        // Without access, nothing is changed or deleted, and nothing breaks.
        let calendar = CalendarFeature(eventStore: EventStore(), defaults: defaults)
        let lunch = DayEvent(id: "x", title: "Lunch", start: noon, end: noon + 3600)
        #expect(!calendar.update(lunch, title: "Brunch", start: noon, end: noon + 3600))
        calendar.delete(lunch)
        #expect(calendar.notice == nil)
    }

    @Test func settingsPersist() {
        let store = EventStore()
        CalendarFeature(eventStore: store, defaults: defaults).showsAllDay = false
        CalendarFeature(eventStore: store, defaults: defaults).countsDownToMeetings = false
        #expect(!CalendarFeature(eventStore: store, defaults: defaults).showsAllDay)
        #expect(!CalendarFeature(eventStore: store, defaults: defaults).countsDownToMeetings)
    }

    @Test func eventsAreReadFromPlainWords() throws {
        let draft = try #require(EventDraft.parse("Lunch with Sam tomorrow 1pm for 90 min"))
        #expect(draft.title == "Lunch with Sam")
        #expect(!draft.isAllDay)
        #expect(draft.duration == 90 * 60)
        #expect(Calendar.current.isDateInTomorrow(draft.start))
        #expect(EventDraft.parse("Lunch with Sam") == nil, "an event needs a time")
    }

    @Test func dueLabelsAreShortAndRelative() throws {
        let calendar = Calendar.current
        let now = try #require(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: noon))
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))
        #expect(DueLabel.text(for: calendar.startOfDay(for: now), hasTime: false, now: now) == "Today")
        #expect(DueLabel.text(for: tomorrow, hasTime: false, now: now) == "Tomorrow")
        #expect(DueLabel.text(for: tomorrow + 3600 * 9, hasTime: true, now: now).hasPrefix("Tomorrow "))
    }
}
