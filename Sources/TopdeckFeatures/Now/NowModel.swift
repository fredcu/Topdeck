// SPDX-License-Identifier: MIT
import Foundation
import Observation

/// What the add field makes of its text.
public enum NowEntryKind: String, CaseIterable, Identifiable, Sendable {
    case event = "Event"
    case note = "Note"

    public var id: Self { self }
    public var title: String { rawValue }
}

/// What the second row's add field is doing: open or not, its text, and which kind of entry it is
/// making. Shared by the plus button, the field and the body, which reads the day picked in the grid.
@MainActor
@Observable
public final class NowModel {
    public var isAdding = false
    public var draft = ""
    /// The kind picked by hand for this entry; nil while the field chooses as the text is typed.
    public var picked: NowEntryKind?
    /// The colour a new note gets; nil for none. Only a note has one.
    public var noteColor: NoteColor?
    /// The window a new note opens in: on the desktop, on top, or none. Never both.
    public private(set) var noteWindow: NoteWindow?
    /// A problem saving, shown where the chips are. Clears itself as the text changes.
    public private(set) var problem: String?

    /// The colours the add field offers, in order. A note may have any of `NoteColor`; these are the
    /// five the field shows.
    public static let noteColors: [NoteColor] = [.yellow, .orange, .green, .blue, .purple]

    public init() {}

    /// Opens the field, empty.
    public func begin() {
        draft = ""
        picked = nil
        noteColor = nil
        noteWindow = nil
        problem = nil
        isAdding = true
    }

    /// Picks a colour for the note; picking the same one again takes it off.
    public func pick(_ color: NoteColor) {
        noteColor = noteColor == color ? nil : color
    }

    /// Turns a window for the note on; turning the one that is on off. Desktop and On Top exclude each other.
    public func toggle(_ window: NoteWindow) {
        noteWindow = noteWindow == window ? nil : window
    }

    /// Closes the field and keeps nothing.
    public func cancel() {
        isAdding = false
        draft = ""
        picked = nil
        noteColor = nil
        noteWindow = nil
        problem = nil
    }

    /// Esc: closes the field and drops its text. False, so the deck can close, when no field is open.
    public func escape() -> Bool {
        guard isAdding else { return false }
        cancel()
        return true
    }

    /// Event when the text has a date or time `EventDraft` understands, otherwise Note, until the user
    /// picks by hand. Only the kinds that can be saved are offered.
    public func kind(canEvent: Bool = true, canNote: Bool = true) -> NowEntryKind {
        if let picked, picked == .event ? canEvent : canNote { return picked }
        if !canNote { return .event }
        if !canEvent { return .note }
        return Self.detect(draft)
    }

    public static func detect(_ text: String) -> NowEntryKind {
        EventDraft.parse(text) != nil ? .event : .note
    }

    /// Tab: the other kind, for this entry.
    public func toggleKind(canEvent: Bool = true, canNote: Bool = true) {
        guard canEvent, canNote else { return }
        picked = kind(canEvent: canEvent, canNote: canNote) == .event ? .note : .event
    }

    /// The date and time an event would get, as chips: "Tue 3" and "15:00". A day picked in the grid
    /// stands in for a date the text doesn't have.
    public static func chips(for text: String, on day: Date?, calendar: Calendar = .current) -> [String] {
        guard let draft = EventDraft.parse(text, on: day, calendar: calendar) else { return [] }
        let date = draft.start.formatted(.dateTime.weekday(.abbreviated).day())
        return draft.isAllDay ? [date] : [date, draft.start.formatted(.dateTime.hour().minute())]
    }

    /// Saves the entry: an event through `calendar`, or a note whose first line is the text, with the
    /// colour and window picked. Closes the field on success; on failure the text stays.
    @discardableResult
    public func submit(calendar: CalendarFeature?, notes: NotesFeature?, day: Date?) -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        switch kind(canEvent: calendar != nil, canNote: notes != nil) {
        case .event:
            guard let calendar, calendar.addEvent(text, on: day) else {
                problem = calendar?.notice ?? "Couldn't add the event"
                return false
            }
        case .note:
            guard let notes else { return false }
            let id = notes.add(text)
            if let noteColor { notes.setColor(id, noteColor) }
            if let noteWindow { notes.setWindow(id, noteWindow) }
        }
        cancel()
        return true
    }

    /// Typing clears a problem.
    public func edited() { problem = nil }
}
