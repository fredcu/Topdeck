// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

/// Plan's task column: the open reminders in the order of their dates (or of their lists), with the
/// last ones completed beneath them. A task due now gets a banner on top. Right-click a task for its
/// actions; double-click its title to rename it.
struct TasksView: View {
    let tasks: TasksFeature
    /// Tasks just ticked: they show a checkmark for a beat before moving to Completed.
    @State private var ticking: Set<TaskItem.ID> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How many completed tasks stay in view under the open ones.
    static let completedShown = 2

    var body: some View {
        Group {
            if tasks.access != .granted {
                DeckCard(padding: 0) {
                    EventAccessView(
                        access: tasks.access, what: "reminders", settingsPane: "Privacy_Reminders",
                        request: tasks.requestAccess)
                }
            } else {
                VStack(spacing: Deck.Metric.gap) {
                    if let task = tasks.alerting { alertBanner(task) }
                    list
                }
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: tasks.alerting)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var open: [TaskItem] { tasks.sections().flatMap(\.tasks) }

    @ViewBuilder private var list: some View {
        let open = self.open
        let done = Array(tasks.completed.prefix(Self.completedShown))
        if open.isEmpty, done.isEmpty {
            DeckEmptyLine("All done")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(open) { task in
                        TaskRow(tasks: tasks, task: task, ticked: ticking.contains(task.id)) { tick(task) }
                    }
                    ForEach(done) { task in completedRow(task) }
                }
                .padding(.vertical, 4)
            }
            .fadingEdges()
            .padding(.horizontal, 6)
            .overlay(alignment: .bottom) { notice }
        }
    }

    /// A short confirmation, such as "Blocked 30 min at 3:00 PM", over the foot of the list.
    @ViewBuilder private var notice: some View {
        if let text = tasks.notice {
            Text(text)
                .deckText(.detail)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Deck.control))
                .padding(.bottom, 4)
                .transition(.opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: text)
        }
    }

    private func completedRow(_ task: TaskItem) -> some View {
        HStack(spacing: Deck.Metric.gap) {
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) { tasks.reopen(task) }
            } label: {
                TaskCheckbox(done: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reopen \(task.title)")
            Text(task.title).deckText(.caption).strikethrough().lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 36)
        .contextMenu { Button("Delete", role: .destructive) { tasks.delete(task) } }
        .transition(.opacity)
    }

    // MARK: Due alert

    private func alertBanner(_ task: TaskItem) -> some View {
        DeckCard(.signal, padding: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Due now").deckText(.caption)
                    Text(task.title).deckText(.body).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button("Done") { tick(task) }.buttonStyle(.deck(.primary, compact: true))
                Button("Snooze \(TasksFeature.snoozeMinutes) min") { tasks.snooze(task) }
                    .buttonStyle(.deck(compact: true))
                DeckIconButton(.close, label: "Dismiss") { tasks.dismissAlert() }
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Shows the checkmark for a beat, then moves the task to Completed.
    private func tick(_ task: TaskItem) {
        ticking.insert(task.id)
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 350))
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82)) {
                tasks.complete(task)
            }
            ticking.remove(task.id)
        }
    }
}

/// What a task's due date says in its row: "Today", "Mon", "3 Jun".
enum PlanDue {
    static func text(for due: Date, hasTime: Bool, now: Date = .now, calendar: Calendar = .current) -> String {
        let offset =
            calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day
            ?? 0
        let day: String
        switch offset {
        case 0: day = "Today"
        case 1: day = "Tomorrow"
        case -1: day = "Yesterday"
        case 2..<7: day = due.formatted(.dateTime.weekday(.abbreviated))
        default:
            day =
                calendar.component(.year, from: due) == calendar.component(.year, from: now)
                ? due.formatted(.dateTime.day().month(.abbreviated))
                : due.formatted(.dateTime.day().month(.abbreviated).year())
        }
        guard hasTime else { return day }
        return offset == 0
            ? due.formatted(date: .omitted, time: .shortened)
            : "\(day) \(due.formatted(date: .omitted, time: .shortened))"
    }
}

/// A task's checkbox: a ring, filled with a check when done.
private struct TaskCheckbox: View {
    let done: Bool

    var body: some View {
        Circle()
            .strokeBorder(Deck.tertiary, lineWidth: 1.5)
            .background(Circle().fill(done ? Deck.tertiary : .clear))
            .overlay { if done { DeckIconView(.check, size: 11).foregroundStyle(Deck.onFill) } }
            .frame(width: 17, height: 17)
            .contentShape(Circle())
    }
}

/// One open task: its checkbox, its title and when it is due, in signal today and in stop when late.
private struct TaskRow: View {
    let tasks: TasksFeature
    let task: TaskItem
    let ticked: Bool
    let tick: () -> Void

    @State private var editing = false
    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Deck.Metric.gap) {
            Button(action: tick) { TaskCheckbox(done: ticked) }
                .buttonStyle(.plain)
                .accessibilityLabel("Complete \(task.title)")
            if editing {
                TextField("Task", text: $title)
                    .textFieldStyle(.plain)
                    .deckText(.body)
                    .focused($focused)
                    .takesKeyboard(editing)
                    .onSubmit(commitRename)
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commitRename() }
                    }
            } else {
                HStack(spacing: 4) {
                    if task.priority != .none {
                        Text(task.priority.marks).font(.system(size: 13, weight: .heavy)).foregroundStyle(
                            Deck.secondary)
                    }
                    Text(task.title).deckText(.body).lineLimit(1)
                }
                .opacity(ticked ? 0.5 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: beginRename)
            }
            if let due = task.due {
                Text(PlanDue.text(for: due, hasTime: task.hasTime))
                    .deckText(.caption, color: dueColor)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .contextMenu { menuItems }
        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .bottom))))
        .accessibilityAction(named: "Rename", beginRename)
        .accessibilityAction(named: "Block Time in Calendar") { tasks.blockTime(for: task) }
    }

    private var dueColor: Color {
        switch task.group() {
        case .overdue: Deck.stop
        case .today: Deck.signal
        default: Deck.tertiary
        }
    }

    @ViewBuilder private var menuItems: some View {
        Button("Rename", action: beginRename)
        Menu("Due") {
            ForEach(DueChoice.allCases) { choice in
                Button(choice.name) { tasks.setDue(task, to: choice) }
            }
        }
        Picker(
            "Priority",
            selection: Binding(get: { task.priority }, set: { tasks.setPriority(task, to: $0) })
        ) {
            ForEach(TaskPriority.allCases, id: \.self) { priority in
                Text(priority == .none ? "None" : "\(priority.name) \(priority.marks)").tag(priority)
            }
        }
        .pickerStyle(.menu)
        if tasks.lists.count > 1 {
            Picker(
                "List",
                selection: Binding(get: { task.listID ?? "" }, set: { tasks.move(task, toList: $0) })
            ) {
                ForEach(tasks.lists) { list in
                    Text(list.title).tag(list.id)
                }
            }
            .pickerStyle(.menu)
        }
        Button("Block \(tasks.blockMinutes) Min in Calendar") { tasks.blockTime(for: task) }
        Divider()
        Button("Delete", role: .destructive) { tasks.delete(task) }
    }

    private func beginRename() {
        title = task.title
        editing = true
        Task { @MainActor in focused = true }  // once the field is on screen
    }

    private func commitRename() {
        guard editing else { return }
        editing = false
        tasks.rename(task, to: title)
    }
}
