// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckSurface

/// The left column: the next event that hasn't ended with a Join button when it has a link, the rest of
/// today's events, and the notes, in the order Settings sets (the most recently edited first to begin with),
/// each with a square in its colour. With nothing left today the Today
/// section is gone and Notes moves up; with nothing at all, one line.
struct NowTodayColumn: View {
    let calendar: CalendarFeature?
    let notes: NotesFeature?
    let metrics: NowMetrics
    let now: Date
    let openNote: (Note) -> Void

    var body: some View {
        let agenda = NowAgenda(events: calendar?.rangeEvents ?? [], now: now)
        let recent = notes?.visibleNotes ?? []
        VStack(alignment: .leading, spacing: 0) {
            if let next = agenda.next {
                Text("Today").deckText(.item).frame(height: 22)
                headline(next)
                ForEach(Array(agenda.later.prefix(metrics.laterEvents))) { event in later(event) }
                if !recent.isEmpty { DeckSeparator().padding(.vertical, 8) }
            }
            if let notes, !recent.isEmpty {
                Text("Notes").deckText(.item).frame(height: 22)
                notesList(recent, notes: notes)
            }
            if agenda.next == nil, recent.isEmpty {
                DeckEmptyLine("Nothing today")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    // MARK: Today

    private func headline(_ event: DayEvent) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(event.title).deckText(.body).fontWeight(.semibold).lineLimit(1)
                Text(Self.when(event, now: now)).deckText(.detail).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let calendar, event.meeting != nil {
                Button("Join") { calendar.join(event) }
                    .buttonStyle(.deck(.accent, compact: true))
                    .help("Join on \(event.meeting?.service ?? "the call")")
            }
        }
        .frame(height: 40)
        .accessibilityElement(children: .combine)
    }

    /// "19:30, in 36 min"; "All day" for an all-day event, which has no countdown.
    static func when(_ event: DayEvent, now: Date) -> String {
        if event.isAllDay { return "All day" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        return NowAgenda.countdown(to: event, now: now).map { "\(start), \($0)" } ?? start
    }

    private func later(_ event: DayEvent) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Deck.tertiary).frame(width: 3, height: 14)
                .frame(width: 14)
            Text(event.title).deckText(.body).lineLimit(1)
            Spacer(minLength: 0)
            Text(event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                .deckText(.caption).lineLimit(1)
        }
        .frame(height: metrics.itemHeight)
        .accessibilityElement(children: .combine)
    }

    // MARK: Notes

    private func notesList(_ recent: [Note], notes: NotesFeature) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(recent) { note in
                    NoteListRow(notes: notes, note: note, height: metrics.itemHeight, open: openNote)
                }
            }
        }
        .fadingEdges(atStart: false)
    }
}

/// One note in the list: a square in its colour, its title, and a pin mark when it has a window. A click
/// opens it in a floating window; the context menu sets its colour and window, shows it in Finder, shares
/// it, and deletes it after a confirmation.
private struct NoteListRow: View {
    let notes: NotesFeature
    let note: Note
    let height: CGFloat
    let open: (Note) -> Void

    @State private var confirmsDelete = false

    var body: some View {
        Button {
            open(note)
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(note.color?.swatch ?? Deck.control)
                    .frame(width: 13, height: 13)
                    .frame(width: 14)
                Text(note.title).deckText(.body).lineLimit(1)
                Spacer(minLength: 0)
                if note.window != nil {
                    DeckIconView(.pin, size: 12).foregroundStyle(Deck.tertiary)
                }
            }
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag { notes.fileURL(for: note.id).flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
        .contextMenu { menu }
        .deckPopover(isPresented: $confirmsDelete) {
            VStack(alignment: .leading, spacing: Deck.Metric.gap) {
                Text("Move \u{201C}\(note.title)\u{201D} to the Trash?").deckText(.body).lineLimit(2)
                HStack(spacing: 8) {
                    Button("Cancel") { confirmsDelete = false }.buttonStyle(.deck(compact: true))
                    Button("Delete") {
                        confirmsDelete = false
                        notes.delete(note.id)
                    }
                    .buttonStyle(.deck(.accent, compact: true))
                }
            }
            .padding(12)
            .frame(width: 220, alignment: .leading)
        }
        .accessibilityLabel(note.window != nil ? "\(note.title), pinned" : note.title)
        .accessibilityHint(note.window != nil ? "Brings the note forward" : "Opens the note in a window")
        .accessibilityActions {
            Button("Pin to Desktop") { notes.setWindow(note.id, .desktop) }
            Button("Keep on Top") { notes.setWindow(note.id, .top) }
            if note.window != nil { Button("Unpin") { notes.setWindow(note.id, nil) } }
            Button("Delete") { confirmsDelete = true }
        }
    }

    @ViewBuilder private var menu: some View {
        Picker("Colour", selection: Binding(get: { note.color }, set: { notes.setColor(note.id, $0) })) {
            Text("No Colour").tag(NoteColor?.none)
            ForEach(NoteColor.allCases) { color in Text(color.name).tag(NoteColor?.some(color)) }
        }
        .pickerStyle(.inline)
        Divider()
        if note.window != .desktop { Button("Pin to Desktop") { notes.setWindow(note.id, .desktop) } }
        if note.window != .top { Button("Keep on Top") { notes.setWindow(note.id, .top) } }
        if note.window != nil { Button("Unpin") { notes.setWindow(note.id, nil) } }
        Divider()
        Button(note.isPinned ? "Stop Keeping First" : "Keep First in List") { notes.togglePin(note.id) }
        ShareLink(item: note.text, subject: Text(note.title)) { Text("Share\u{2026}") }
        Button("Reveal in Finder") {
            if let url = notes.fileURL(for: note.id) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Divider()
        Button("Delete\u{2026}", role: .destructive) { confirmsDelete = true }
    }
}
