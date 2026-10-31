// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

/// Plan's agenda card: the day's events, each with its time, its calendar's color and a Join button
/// when it has a video call that hasn't ended. Past events are dimmed. Your own events can be edited
/// in place (double-click, or the context menu) or deleted from the notch.
struct CalendarView: View {
    let calendar: CalendarFeature
    /// The event being edited in place.
    @State private var editing: DayEvent.ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(calendar: CalendarFeature, editing: DayEvent.ID? = nil) {
        self.calendar = calendar
        _editing = State(initialValue: editing)
    }

    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85) }

    var body: some View {
        DeckCard(padding: 0) {
            if calendar.access != .granted {
                EventAccessView(
                    access: calendar.access, what: "calendars", settingsPane: "Privacy_Calendars",
                    request: calendar.requestAccess)
            } else if calendar.dayEvents.isEmpty {
                DeckEmptyLine(calendar.dayOffset == 0 ? "Nothing today" : "Nothing planned")
            } else {
                agenda
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var agenda: some View {
        ScrollViewReader { list in
            ScrollView {
                // The minutes in "in 28 minutes" and the dimming of what is over follow the clock.
                TimelineView(.everyMinute) { context in
                    LazyVStack(spacing: 0) {
                        ForEach(Array(calendar.dayEvents.enumerated()), id: \.element.id) { index, event in
                            if index > 0 { DeckSeparator() }
                            row(event, now: context.date)
                        }
                    }
                }
                .padding(.horizontal, Deck.Metric.cardPadding)
                .padding(.vertical, 6)
            }
            .fadingEdges()
            // In a small deck the editor can open below the fold.
            .onChange(of: editing) { _, id in
                guard let id else { return }
                withAnimation(spring) { list.scrollTo(id) }
            }
        }
    }

    @ViewBuilder private func row(_ event: DayEvent, now: Date) -> some View {
        if editing == event.id {
            EventEditor(event: event) { title, start, end in
                if calendar.update(event, title: title, start: start, end: end) {
                    withAnimation(spring) { editing = nil }
                }
            } cancel: {
                withAnimation(spring) { editing = nil }
            }
            .id(event.id)
            .transition(.opacity)
        } else {
            EventRow(calendar: calendar, event: event, now: now, isToday: calendar.dayOffset == 0) {
                withAnimation(spring) { editing = event.id }
            }
            .id(event.id)
            .transition(.opacity)
        }
    }
}

/// What the line under an event's title says.
enum EventDetail {
    /// How soon an upcoming event counts as near enough to say so.
    static let nearly: TimeInterval = 3600
    /// How soon a meeting with a link counts as about to start, which makes its bar signal.
    static let aboutToStart: TimeInterval = 30 * 60

    /// "in 28 minutes" for what starts within the hour today, else where it is.
    static func text(for event: DayEvent, now: Date, isToday: Bool) -> String? {
        let wait = event.start.timeIntervalSince(now)
        if isToday, !event.isAllDay, wait > 0, wait < nearly {
            let minutes = max(1, Int((wait / 60).rounded(.up)))
            return minutes == 1 ? "in 1 minute" : "in \(minutes) minutes"
        }
        return event.location
    }

    /// Whether a meeting with a link is about to start.
    static func isAboutToStart(_ event: DayEvent, now: Date, isToday: Bool) -> Bool {
        let wait = event.start.timeIntervalSince(now)
        return isToday && event.meeting != nil && !event.isDeclined && wait > 0 && wait <= aboutToStart
    }
}

/// One event: when, its calendar's color (signal when a meeting is about to start), its title, and a
/// line under it. Right-click for the context menu; double-click edits one of your own.
private struct EventRow: View {
    let calendar: CalendarFeature
    let event: DayEvent
    let now: Date
    let isToday: Bool
    let edit: () -> Void

    var body: some View {
        let past = isToday && !event.isAllDay && event.end < now
        let joinable = event.meeting != nil && !past && !event.isDeclined && isToday
        let near = EventDetail.isAboutToStart(event, now: now, isToday: isToday)
        HStack(spacing: Deck.Metric.gap) {
            Text(event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                .deckText(.detail)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 52, alignment: .leading)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(near ? Deck.signal : event.color?.color ?? Deck.tertiary)
                .frame(width: 3, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).deckText(.item).lineLimit(1)
                if let detail = EventDetail.text(for: event, now: now, isToday: isToday) {
                    Text(detail).deckText(.caption).lineLimit(1)
                }
            }
            .opacity(past ? 0.45 : 1)
            Spacer(minLength: 0)
            if joinable, let meeting = event.meeting {
                Button("Join") { calendar.join(event) }
                    .buttonStyle(.deck(.accent))
                    .help("Join on \(meeting.service). Right-click to copy the link.")
            }
        }
        .frame(minHeight: 50)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if event.isEditable { edit() } }
        .contextMenu {
            if event.isEditable { Button("Edit", action: edit) }
            if let meeting = event.meeting {
                Button("Join \(meeting.service)") { calendar.join(event) }.disabled(!joinable)
                Button("Copy Link") { calendar.copyLink(event) }
            }
            if event.isEditable {
                Divider()
                Button("Delete Event", role: .destructive) { calendar.delete(event) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if joinable { Button("Join") { calendar.join(event) } }
            if event.isEditable {
                Button("Edit", action: edit)
                Button("Delete") { calendar.delete(event) }
            }
        }
    }
}

/// An event being changed in place: its title, and when it starts and ends (an all-day event keeps
/// its days). Moving the start keeps the length. Return or Save saves; Cancel leaves it as it was.
private struct EventEditor: View {
    let event: DayEvent
    let save: (_ title: String, _ start: Date, _ end: Date) -> Void
    let cancel: () -> Void

    @State private var title: String
    @State private var start: Date
    @State private var end: Date
    @FocusState private var focused: Bool

    init(
        event: DayEvent, save: @escaping (_ title: String, _ start: Date, _ end: Date) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.event = event
        self.save = save
        self.cancel = cancel
        _title = State(initialValue: event.title)
        _start = State(initialValue: event.start)
        _end = State(initialValue: event.end)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && (event.isAllDay || end > start)
    }

    /// Two lines, so it fits even the smallest deck: the title with Cancel and Save, then the times.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(event.color?.color ?? Deck.tertiary)
                    .frame(width: 3, height: 18)
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .deckText(.body)
                    .focused($focused)
                    .takesKeyboard(true)
                    .onSubmit { if canSave { save(title, start, end) } }
                Button("Cancel", action: cancel).buttonStyle(.deck(compact: true))
                Button("Save") { save(title, start, end) }
                    .buttonStyle(.deck(.primary, compact: true))
                    .disabled(!canSave)
            }
            HStack(spacing: 6) { when }
                .padding(.leading, 11)  // under the title, past the color bar
                .datePickerStyle(.field)
                .labelsHidden()
        }
        .padding(.vertical, 8)
        .onChange(of: start) { old, new in end += new.timeIntervalSince(old) }
        .onAppear { Task { @MainActor in focused = true } }
    }

    @ViewBuilder private var when: some View {
        if event.isAllDay {
            Text("All day").deckText(.caption)
        } else {
            DatePicker("Starts", selection: $start, displayedComponents: [.date, .hourAndMinute])
            Text("–").deckText(.caption)
            DatePicker("Ends", selection: $end, displayedComponents: .hourAndMinute)
        }
    }
}
