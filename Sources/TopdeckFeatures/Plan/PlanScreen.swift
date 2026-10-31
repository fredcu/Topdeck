// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckCore
import TopdeckSurface

/// The Plan space's body: the agenda card beside the task column. Either one alone fills the screen
/// when the other feature is off.
public struct PlanScreen: View {
    let calendar: CalendarFeature?
    let tasks: TasksFeature?

    public init(calendar: CalendarFeature?, tasks: TasksFeature?) {
        self.calendar = calendar
        self.tasks = tasks
    }

    public var body: some View {
        if let calendar, let tasks {
            DeckWeightedRow([1.2, 1]) {
                calendar.view
                tasks.view
            }
        } else if let calendar {
            calendar.view
        } else if let tasks {
            tasks.view
        }
    }
}

/// The day chips beside Plan's title: today and the three days after it. A chip shows that day's
/// agenda.
public struct PlanDayChips: View {
    let calendar: CalendarFeature

    public init(calendar: CalendarFeature) { self.calendar = calendar }

    public var body: some View {
        if calendar.access == .granted {
            let today = Calendar.current.startOfDay(for: .now)
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { offset in
                    let day = Calendar.current.date(byAdding: .day, value: offset, to: today) ?? today
                    DeckChip(day.formatted(.dateTime.weekday(.abbreviated)), selected: calendar.dayOffset == offset) {
                        calendar.dayOffset = offset
                    }
                    .accessibilityLabel(offset == 0 ? "Today" : day.formatted(.dateTime.weekday(.wide)))
                }
            }
        }
    }
}

/// What a line typed into Plan's field becomes.
enum PlanEntry: Equatable {
    case event, task

    /// A line with a time of day ("Lunch tomorrow 1pm") is an event; priority marks, a #list or a
    /// repeat make it a task; so does anything without a time ("Renew domain mon").
    static func route(_ text: String) -> PlanEntry {
        let task = TaskDraft.parse(text)
        if task.priority != .none || task.list != nil || task.repeats != nil { return .task }
        if let event = EventDraft.parse(text), !event.isAllDay { return .event }
        return .task
    }
}

/// Plan's one field, which adds an event or a task from a line of plain words. What it did shows in
/// place of the prompt for a moment.
public struct PlanAddField: View {
    let calendar: CalendarFeature?
    let tasks: TasksFeature?
    @State private var draft = ""

    public init(calendar: CalendarFeature?, tasks: TasksFeature?) {
        self.calendar = calendar
        self.tasks = tasks
    }

    private var canEvent: Bool { calendar?.access == .granted }
    private var canTask: Bool { tasks?.access == .granted }

    public var body: some View {
        if canEvent || canTask {
            DeckField(
                calendar?.notice ?? tasks?.notice ?? "Lunch tomorrow 1pm",
                text: $draft, icon: .plus, onSubmit: submit
            )
            .frame(minWidth: 150, idealWidth: 230, maxWidth: 230)
        }
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Text without a time stays in the field, so it can be finished.
        let route = PlanEntry.route(text)
        let added: Bool
        if route == .event, let calendar, canEvent {
            added = calendar.addEvent(text)
        } else if let tasks, canTask {
            added = tasks.add(text)
        } else if let calendar, canEvent {
            added = calendar.addEvent(text)
        } else {
            added = false
        }
        if added { draft = "" }
    }
}
