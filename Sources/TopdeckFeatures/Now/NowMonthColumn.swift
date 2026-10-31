// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

/// The middle column: the month as a six-week grid with a dot under each day that has events and today
/// filled white, and under it the events from tomorrow on, a week ahead. Picking a day rings it and the
/// list shows that day; picking it again, or today, goes back. Right-click your own event to edit or
/// delete it; editing opens in a popover.
struct NowMonthColumn: View {
    let calendar: CalendarFeature?
    let metrics: NowMetrics
    let now: Date

    @State private var editing: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let month = CalendarMonth(containing: now)
        let granted = calendar?.access == .granted
        let agenda = NowAgenda(events: calendar?.rangeEvents ?? [], now: now)
        VStack(alignment: .leading, spacing: 0) {
            if metrics.showsMonthTitle {
                Text(month.title).deckText(.item).padding(.leading, 4).frame(height: 22)
            }
            HStack(spacing: 0) {
                ForEach(Array(CalendarMonth.weekdayInitials().enumerated()), id: \.offset) { _, initial in
                    Text(initial).deckText(.caption).fontWeight(.semibold)
                        .frame(maxWidth: .infinity).frame(height: 18)
                }
            }
            .padding(.top, 4)
            .accessibilityHidden(true)
            grid(month, agenda: agenda)
            DeckSeparator().padding(.top, 6)
            if let calendar, !granted {
                EventAccessView(
                    access: calendar.access, what: "calendars", settingsPane: "Privacy_Calendars",
                    request: calendar.requestAccess)
            } else if let calendar {
                list(agenda, calendar: calendar)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Grid

    private func grid(_ month: CalendarMonth, agenda: NowAgenda) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(month.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(row, id: \.self) { day in cell(day, month: month, agenda: agenda) }
                }
            }
        }
    }

    private func cell(_ day: Date, month: CalendarMonth, agenda: NowAgenda) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDate(day, inSameDayAs: now)
        let isSelected = calendar?.selectedDay.map { cal.isDate($0, inSameDayAs: day) } ?? false
        let inMonth = month.contains(day)
        let dot = calendar?.access == .granted && agenda.hasEvents(on: day)
        return Button {
            guard let calendar else { return }
            calendar.selectedDay = isToday || isSelected ? nil : cal.startOfDay(for: day)
        } label: {
            ZStack {
                Text("\(cal.component(.day, from: day))")
                    .deckText(.figure, color: isToday ? Deck.onFill : inMonth ? Deck.text : Deck.tertiary)
                    .fontWeight(isToday ? .bold : inMonth ? .semibold : .medium)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(isToday ? Deck.text : .clear))
                    .overlay(Circle().strokeBorder(isSelected ? Deck.text : .clear, lineWidth: 1.5))
                if dot {
                    Circle().fill(Deck.secondary).frame(width: 3, height: 3)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: metrics.dayHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .accessibilityValue(dot ? "Has events" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: List

    private func list(_ agenda: NowAgenda, calendar: CalendarFeature) -> some View {
        let all = calendar.selectedDay.map { agenda.rows(on: $0) } ?? agenda.upcoming
        let rows = metrics.eventRows.map { Array(all.prefix($0)) } ?? all
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    line(row, calendar: calendar)
                }
            }
        }
        .fadingEdges(atStart: false)
    }

    private func line(_ row: AgendaRow, calendar: CalendarFeature) -> some View {
        let event = row.event
        return HStack(spacing: 8) {
            Text(row.day.formatted(.dateTime.weekday(.abbreviated).day())).deckText(.caption).lineLimit(1)
                .frame(width: 42, alignment: .leading)
            Text(event.title).deckText(.body).lineLimit(1)
            Spacer(minLength: 0)
            Text(event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                .deckText(.caption).lineLimit(1)
        }
        .frame(height: metrics.eventHeight)
        .contentShape(Rectangle())
        .contextMenu {
            if event.isEditable {
                Button("Edit") { editing = event.id }
                Button("Delete", role: .destructive) { calendar.delete(event) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if event.isEditable {
                Button("Edit") { editing = event.id }
                Button("Delete") { calendar.delete(event) }
            }
        }
        .deckPopover(
            isPresented: Binding(get: { editing == event.id }, set: { if !$0, editing == event.id { editing = nil } })
        ) {
            EventEditor(event: event) { title, start, end in
                if calendar.update(event, title: title, start: start, end: end) { editing = nil }
            } cancel: {
                editing = nil
            }
            .frame(width: 330)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }
}
