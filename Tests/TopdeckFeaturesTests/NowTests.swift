// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import TopdeckFeatures

/// Now's pure parts: the month grid, what the lists show, the add field's choices, and the sizes.
struct NowCalendarTests {
    /// Monday-first, so the grid doesn't depend on the machine's region.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    private var calendar: Calendar { Self.calendar }

    private func date(_ day: Int, _ hour: Int = 0, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @Test func theGridIsSixWeeksFromTheFirstWeekday() {
        let month = CalendarMonth(containing: date(31, 18), calendar: calendar)
        #expect(month.days.count == 42 && month.rows.count == 6)
        #expect(month.days.first == date(28, month: 9), "Monday 28 September, as on the board")
        #expect(month.days.last == date(8, month: 11))
        #expect(month.contains(date(31)) && !month.contains(date(28, month: 9)) && !month.contains(date(1, month: 11)))
        var sunday = calendar
        sunday.firstWeekday = 1
        #expect(CalendarMonth(containing: date(31), calendar: sunday).days.first == date(27, month: 9))
        #expect(CalendarMonth.weekdayInitials(calendar: calendar).count == 7)
        #expect(CalendarMonth.weekdayInitials(calendar: calendar) == ["M", "T", "W", "T", "F", "S", "S"])
    }

    @Test func aMonthStartingOnTheFirstWeekdayStillHasSixRows() {
        let february = CalendarMonth(containing: date(10, month: 2), calendar: calendar)  // 2026: Sunday the 1st
        #expect(february.days.count == 42)
        let march = CalendarMonth(containing: date(5, month: 3), calendar: calendar)  // Sunday 1 March 2026
        #expect(march.days.count == 42)
    }

    @Test func theLoadedRangeCoversTheGridAndAWeekAhead() {
        let now = date(31, 18)
        let range = CalendarMonth.loadedRange(for: now, calendar: calendar)
        #expect(range.lowerBound == date(28, month: 9) && range.upperBound == date(9, month: 11), "to the grid's end")
        let late = CalendarMonth.loadedRange(for: date(30, month: 11), calendar: calendar)
        #expect(late.upperBound >= date(8, month: 12), "a week ahead of the 30th")
    }

    private func event(_ id: String, _ title: String, from start: Date, minutes: Double = 60, allDay: Bool = false)
        -> DayEvent
    {
        DayEvent(id: id, title: title, start: start, end: start + minutes * 60, isAllDay: allDay)
    }

    @Test func todayLeadsWithTheNextEventThatHasNotEnded() {
        let now = date(31, 18)
        let agenda = NowAgenda(
            events: [
                event("a", "Over", from: date(31, 9)),
                event("b", "Dinner", from: date(31, 20)),
                event("c", "Holiday", from: date(31), minutes: 1439, allDay: true),
                event("d", "Team sync", from: date(31, 19)),
                event("e", "Tomorrow", from: date(1, 9, month: 11)),
            ], now: now, calendar: calendar)
        #expect(agenda.next?.title == "Team sync")
        #expect(agenda.later.map(\.title) == ["Dinner", "Holiday"], "timed first, all-day last")
    }

    @Test func anEventUnderwayIsStillNextAndDeclinedOnesNeverAre() {
        let now = date(31, 18)
        var declined = event("x", "Declined", from: date(31, 18))
        declined.isDeclined = true
        let agenda = NowAgenda(
            events: [declined, event("y", "Underway", from: date(31, 17) + 1800, minutes: 90)], now: now,
            calendar: calendar)
        #expect(agenda.next?.title == "Underway" && agenda.later.isEmpty)
        #expect(NowAgenda(events: [], now: now, calendar: calendar).next == nil)
    }

    @Test func countdownsAreShortAndAllDayHasNone() {
        let now = date(31, 18)
        #expect(NowAgenda.countdown(to: event("a", "A", from: now + 36 * 60), now: now) == "in 36 min")
        #expect(NowAgenda.countdown(to: event("a", "A", from: now + 30), now: now) == "in 1 min")
        #expect(NowAgenda.countdown(to: event("a", "A", from: now + 125 * 60), now: now) == "in 2 h 5 min")
        #expect(NowAgenda.countdown(to: event("a", "A", from: now + 120 * 60), now: now) == "in 2 h")
        #expect(NowAgenda.countdown(to: event("a", "A", from: now - 600), now: now) == "now")
        #expect(NowAgenda.countdown(to: event("a", "A", from: now + 3 * 86_400), now: now) == nil)
        #expect(NowAgenda.countdown(to: event("a", "A", from: date(31), allDay: true), now: now) == nil)
    }

    @Test func dotsMarkEveryDayAnEventTouches() {
        let agenda = NowAgenda(
            events: [
                event("a", "Trip", from: date(3, month: 11), minutes: 3 * 24 * 60 - 1, allDay: true),
                event("b", "Late", from: date(5, 23, month: 11), minutes: 30),
            ], now: date(31, 18), calendar: calendar)
        #expect([3, 4, 5].allSatisfy { agenda.hasEvents(on: date($0, 0, month: 11)) }, "a long event, each day")
        #expect(!agenda.hasEvents(on: date(2, month: 11)) && !agenda.hasEvents(on: date(6, month: 11)))
    }

    @Test func theListUnderTheGridIsTomorrowOnForAWeek() {
        let agenda = NowAgenda(
            events: [
                event("t", "Today", from: date(31, 20)),
                event("a", "Recreation", from: date(2, month: 11), minutes: 1439, allDay: true),
                event("b", "Review", from: date(3, 15, month: 11)),
                event("c", "Far", from: date(20, 9, month: 11)),
                event("d", "Edge", from: date(7, 9, month: 11)),
            ], now: date(31, 18), calendar: calendar)
        // Tomorrow is Sunday 1 November; a week ahead reaches Saturday the 7th.
        #expect(agenda.upcoming.map(\.event.title) == ["Recreation", "Review", "Edge"])
        #expect(agenda.rows(on: date(3, month: 11)).map(\.event.title) == ["Review"])
        #expect(agenda.rows(on: date(31)).map(\.event.title) == ["Today"])
    }

    @Test func aLongEventIsListedOnceInTheWindow() {
        let agenda = NowAgenda(
            events: [event("a", "Trip", from: date(2, month: 11), minutes: 3 * 24 * 60 - 1, allDay: true)],
            now: date(31, 18), calendar: calendar)
        #expect(agenda.upcoming.count == 1 && agenda.upcoming.first?.day == date(2, month: 11))
        #expect(agenda.rows(on: date(4, month: 11)).count == 1, "but a picked day still shows it")
    }
}

@MainActor
struct NowAddFieldTests {
    @Test func textWithADateOrATimeIsAnEventAndTheRestIsANote() {
        #expect(NowModel.detect("Call school 3pm") == .event)
        #expect(NowModel.detect("Lunch tomorrow 1pm for 90 min") == .event)
        #expect(NowModel.detect("Kitchen measurements") == .note)
        #expect(NowModel.detect("") == .note)
    }

    @Test func theKindFollowsTheTextUntilPickedByHand() {
        let model = NowModel()
        model.begin()
        model.draft = "Call school 3pm"
        #expect(model.kind() == .event)
        model.toggleKind()
        #expect(model.kind() == .note, "Tab picks the other one")
        model.draft = "Gift ideas"
        #expect(model.kind() == .note, "and it stays picked")
        model.picked = .event
        #expect(model.kind() == .event)
        model.cancel()
        model.begin()
        model.draft = "Gift ideas"
        #expect(model.kind() == .note, "a new entry chooses for itself again")
    }

    @Test func escapeClosesAnOpenFieldAndOtherwiseLeavesTheDeckToClose() {
        let model = NowModel()
        #expect(!model.escape(), "no field: Esc is the deck's")
        model.begin()
        model.draft = "Gift ideas"
        #expect(model.escape() && !model.isAdding && model.draft.isEmpty)
        #expect(!model.escape(), "the next Esc closes the deck")
    }

    @Test func aKindThatCannotBeSavedIsNotOffered() {
        let model = NowModel()
        model.draft = "Call school 3pm"
        #expect(model.kind(canEvent: false, canNote: true) == .note)
        #expect(model.kind(canEvent: true, canNote: false) == .event)
        model.picked = .event
        #expect(model.kind(canEvent: false, canNote: true) == .note)
        model.toggleKind(canEvent: false, canNote: true)
        #expect(model.picked == .event, "nothing to switch to")
    }

    @Test func chipsShowTheParsedDateAndTime() {
        let chips = NowModel.chips(for: "Call school tomorrow 3pm", on: nil)
        #expect(
            chips.count == 2 && (chips[1].contains("15") || chips[1].contains("3")) && !chips[0].isEmpty, "\(chips)")
        #expect(NowModel.chips(for: "Kitchen measurements", on: nil).isEmpty)
        #expect(NowModel.chips(for: "Dentist tomorrow", on: nil).count == 1, "a date with no time is all-day")
    }

    @Test func aDayPickedInTheGridStandsInForADateTheTextLacks() throws {
        let calendar = Calendar.current
        let day = try #require(calendar.date(byAdding: .day, value: 9, to: calendar.startOfDay(for: .now)))
        let timed = try #require(EventDraft.parse("Call school 3pm", on: day))
        #expect(calendar.isDate(timed.start, inSameDayAs: day) && !timed.isAllDay)
        #expect(calendar.component(.hour, from: timed.start) == 15)
        let plain = try #require(EventDraft.parse("Gift ideas", on: day))
        #expect(plain.isAllDay && calendar.isDate(plain.start, inSameDayAs: day) && plain.title == "Gift ideas")
        let own = try #require(EventDraft.parse("Lunch tomorrow 1pm", on: day))
        #expect(calendar.isDateInTomorrow(own.start), "a date of its own wins")
        #expect(EventDraft.parse("Gift ideas") == nil)
        #expect(NowModel.chips(for: "Gift ideas", on: day).count == 1, "the day's chip, for an Event forced on it")
    }

    @Test func aNoteIsSavedWithItsTextAsTheFirstLineAndCanBePinned() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "NowNotes-\(UUID().uuidString)")
        let notes = NotesFeature(directory: folder, defaults: UserDefaults(suiteName: "Now.\(UUID())")!)
        notes.phase = .foreground
        let model = NowModel()
        model.begin()
        model.draft = "  Gift ideas  "
        #expect(model.submit(calendar: nil, notes: notes, day: nil))
        #expect(!model.isAdding && model.draft.isEmpty, "saving closes the field")
        let saved = try #require(notes.notes.first)
        #expect(saved.title == "Gift ideas" && saved.window == nil)
        model.begin()
        model.draft = "Trip packing list"
        #expect(model.submit(calendar: nil, notes: notes, day: nil, pin: true))
        #expect(notes.recent.first?.window == .desktop, "⌘Return also pins it to the desktop")
        notes.flush()
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func anEventWithoutADateStaysInTheField() {
        let model = NowModel()
        model.begin()
        model.draft = "Gift ideas"
        model.picked = .event
        let calendar = CalendarFeature(eventStore: EventStore(), defaults: UserDefaults(suiteName: "Now.\(UUID())")!)
        #expect(!model.submit(calendar: calendar, notes: nil, day: nil), "no access, no date: nothing saved")
        #expect(model.isAdding && model.draft == "Gift ideas")
        #expect(model.problem != nil)
        model.edited()
        #expect(model.problem == nil)
        model.draft = "   "
        #expect(!model.submit(calendar: nil, notes: nil, day: nil), "empty text is never saved")
    }

    @Test func cancelKeepsNothing() {
        let model = NowModel()
        model.begin()
        model.draft = "Half a thought"
        model.picked = .note
        model.cancel()
        #expect(!model.isAdding && model.draft.isEmpty && model.picked == nil)
    }
}

struct NowSlotTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let zoom = MeetingLink(URL(string: "https://zoom.us/j/1")!)

    private func event(in minutes: Double, meeting: Bool = true) -> DayEvent {
        DayEvent(
            id: "e\(minutes)", title: "E", start: now + minutes * 60, end: now + minutes * 60 + 1800,
            meeting: meeting ? zoom : nil)
    }

    @Test func aMeetingWithALinkStartingWithinHalfAnHourTakesTheSlot() {
        #expect(NowSlot.meeting(in: [event(in: 28)], now: now) != nil)
        #expect(NowSlot.meeting(in: [event(in: 28, meeting: false)], now: now) == nil, "no call to join")
        #expect(NowSlot.meeting(in: [event(in: 90)], now: now) == nil, "not yet")
        #expect(NowSlot.meeting(in: [event(in: -5)], now: now) == nil, "already started")
        #expect(
            NowSlot.meeting(in: [event(in: 20), event(in: 10)], now: now)?.id == event(in: 10).id, "the sooner one")
    }
}

struct NowMetricsTests {
    @Test func theDefaultAndTheSmallestDeckMatchTheBoards() {
        let normal = NowMetrics(size: CGSize(width: 700, height: 333))
        #expect(normal.left == 176 && normal.middle == 214 && normal.artwork == 52)
        #expect(normal.showsMonthTitle && normal.showsNextLyric && normal.showsDailyForecast)
        #expect(normal.dayHeight == 26 && normal.eventHeight == 36 && normal.itemHeight == 30)
        let smallest = NowMetrics(size: CGSize(width: 620, height: 243))
        #expect(smallest.left == 150 && smallest.middle == 192 && smallest.artwork == 36)
        #expect(!smallest.showsMonthTitle && !smallest.showsNextLyric && !smallest.showsDailyForecast)
        #expect(smallest.dayHeight == 21 && smallest.eventHeight == 30 && smallest.itemHeight == 26)
    }
}
