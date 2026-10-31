// SPDX-License-Identifier: MIT
import Foundation

/// The month grid on Now: six weeks starting on the system's first weekday, so a month never changes
/// the grid's height. Pure, so it's tested without any UI.
struct CalendarMonth: Equatable, Sendable {
    static let weeks = 6
    /// How many days after today the list under the grid reaches.
    static let lookahead = 7

    /// The first day of the month on show.
    let first: Date
    /// The grid's 42 days, each as its start, row by row.
    let days: [Date]
    private let calendar: Calendar

    init(containing date: Date, calendar: Calendar = .current) {
        self.calendar = calendar
        let month = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        first = month
        // Back to the week's first day: the weekday's distance from `firstWeekday`, 0 to 6.
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -lead, to: month) ?? month
        days = (0..<(Self.weeks * 7)).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// "October 2026".
    var title: String { first.formatted(.dateTime.month(.wide).year()) }

    /// Whether `day` is in the month on show, as opposed to a leading or trailing day.
    func contains(_ day: Date) -> Bool { calendar.isDate(day, equalTo: first, toGranularity: .month) }

    /// The grid's rows.
    var rows: [[Date]] { stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<$0 + 7]) } }

    /// "M T W T F S S", starting on the system's first weekday.
    static func weekdayInitials(calendar: Calendar = .current) -> [String] {
        // One letter each: some regions' very short names are two ("Th", "Sa").
        let symbols = calendar.veryShortStandaloneWeekdaySymbols.map { String($0.prefix(1)) }
        let lead = calendar.firstWeekday - 1
        return Array(symbols[lead...] + symbols[..<lead])
    }

    /// Everything the grid's dots and the lists need: from the grid's first day to the later of its last
    /// day and a week after today.
    static func loadedRange(for now: Date, calendar: Calendar = .current) -> Range<Date> {
        let grid = CalendarMonth(containing: now, calendar: calendar)
        let start = grid.days[0]
        let today = calendar.startOfDay(for: now)
        let gridEnd = calendar.date(byAdding: .day, value: 1, to: grid.days[grid.days.count - 1]) ?? today
        let weekAhead = calendar.date(byAdding: .day, value: lookahead + 1, to: today) ?? today
        return start..<max(gridEnd, weekAhead)
    }
}

extension DayEvent {
    /// Whether the event is on `day` at any moment of it.
    func occurs(on day: Date, calendar: Calendar = .current) -> Bool {
        let begin = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: begin) else { return false }
        return start < end && max(self.end, start.addingTimeInterval(1)) > begin
    }
}

/// One line of the lists under the grid: an event, and the day it is listed under.
struct AgendaRow: Identifiable, Equatable, Sendable {
    let day: Date
    let event: DayEvent
    var id: String { "\(event.id)@\(day.timeIntervalSince1970)" }
}

/// What Now shows of the calendar at one moment, worked out from the events loaded for the grid.
struct NowAgenda: Equatable, Sendable {
    /// Today's events that haven't ended, the next one first: timed ones by start, then all-day.
    let today: [DayEvent]
    private let events: [DayEvent]
    private let calendar: Calendar
    private let start: Date

    init(events: [DayEvent], now: Date, calendar: Calendar = .current) {
        self.events = events.filter { !$0.isDeclined }
        self.calendar = calendar
        start = calendar.startOfDay(for: now)
        today = self.events
            .filter { $0.occurs(on: now, calendar: calendar) && ($0.isAllDay || $0.end > now) }
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return rhs.isAllDay }
                return (lhs.start, lhs.title) < (rhs.start, rhs.title)
            }
    }

    /// The event the Today section leads with.
    var next: DayEvent? { today.first }
    /// The rest of today's events.
    var later: ArraySlice<DayEvent> { today.dropFirst() }

    /// Whether anything happens on `day`: the grid's dot.
    func hasEvents(on day: Date) -> Bool { events.contains { $0.occurs(on: day, calendar: calendar) } }

    /// The events of one day, all-day ones first, then by start.
    func rows(on day: Date) -> [AgendaRow] {
        let day = calendar.startOfDay(for: day)
        return events.filter { $0.occurs(on: day, calendar: calendar) }.sorted(by: DayEvent.agendaOrder)
            .map { AgendaRow(day: day, event: $0) }
    }

    /// The events from tomorrow on, a week ahead, each under the first of those days it is on.
    var upcoming: [AgendaRow] {
        let days = (1...CalendarMonth.lookahead).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        return days.enumerated().flatMap { index, day in
            // A long event is listed once, under the first day of the window it is on.
            rows(on: day).filter { index == 0 || !$0.event.occurs(on: days[index - 1], calendar: calendar) }
        }
    }

    /// "in 36 min", "in 2 h 5 min"; nil for an all-day event, one that has started, or one far off.
    static func countdown(to event: DayEvent, now: Date) -> String? {
        guard !event.isAllDay else { return nil }
        let wait = event.start.timeIntervalSince(now)
        guard wait > 0 else { return "now" }
        let minutes = max(1, Int((wait / 60).rounded(.up)))
        guard minutes < 24 * 60 else { return nil }
        return minutes < 60
            ? "in \(minutes) min"
            : minutes % 60 == 0 ? "in \(minutes / 60) h" : "in \(minutes / 60) h \(minutes % 60) min"
    }
}
