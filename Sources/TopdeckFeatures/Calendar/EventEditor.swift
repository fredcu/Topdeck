// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

/// An event being changed in place: its title, and when it starts and ends (an all-day event keeps
/// its days). Moving the start keeps the length. Return or Save saves; Cancel leaves it as it was.
struct EventEditor: View {
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
