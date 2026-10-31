// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

/// Now's actions in the second row, before pin and Settings: the running timer and Keep Awake as small
/// chips, and the plus that opens the add field (which then hides it).
public struct NowActions: View {
    let timer: TimerFeature?
    let model: NowModel
    /// Something can be added: Calendar or Notes is on.
    let canAdd: Bool

    public init(timer: TimerFeature?, model: NowModel, canAdd: Bool) {
        self.timer = timer
        self.model = model
        self.canAdd = canAdd
    }

    public var body: some View {
        HStack(spacing: 2) {
            if let timer {
                if let countdown = timer.countdown {
                    DeckStatusChip {
                        if let end = countdown.endsAt {
                            Text(timerInterval: Date.now...max(end, .now), countsDown: true)
                        } else {
                            Text(formatTime(countdown.remaining))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Timer")
                    .padding(.trailing, 2)
                }
                if timer.keepsAwake, let until = timer.awakeUntil {
                    DeckStatusChip(icon: .moon) {
                        if until != .distantFuture {
                            Text(timerInterval: Date.now...max(until, .now), countsDown: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Keep Awake")
                    .padding(.trailing, 2)
                }
            }
            if canAdd, !model.isAdding {
                DeckIconButton(.plus, label: "Add") { model.begin() }
            }
        }
    }
}

/// The one slot between Now's clock and its actions. An agent waiting for an answer comes first, then a
/// meeting about to start, then the add field when it is open; otherwise nothing. The rows below never
/// move for any of them.
public struct NowSlot: View {
    let agent: AnyView?
    let calendar: CalendarFeature?
    let notes: NotesFeature?
    let model: NowModel

    /// How soon a meeting with a link counts as about to start: the half hour the agenda used to signal.
    public nonisolated static let aboutToStart: TimeInterval = 30 * 60

    public init(agent: AnyView?, calendar: CalendarFeature?, notes: NotesFeature?, model: NowModel) {
        self.agent = agent
        self.calendar = calendar
        self.notes = notes
        self.model = model
    }

    public var body: some View {
        if let agent {
            agent
        } else if let calendar, let meeting = Self.meeting(in: calendar.events, now: .now) {
            MeetingBar(calendar: calendar, event: meeting)
        } else if model.isAdding {
            NowAddField(calendar: calendar, notes: notes, model: model)
        }
    }

    /// The first meeting today that has a link and starts within the threshold.
    nonisolated static func meeting(in events: [DayEvent], now: Date) -> DayEvent? {
        events
            .filter { event in
                let wait = event.start.timeIntervalSince(now)
                return !event.isAllDay && event.meeting != nil && !event.isDeclined && wait > 0 && wait <= aboutToStart
            }
            .min { $0.start < $1.start }
    }
}

/// A meeting about to start: its title and a Join button, in the amber bar.
private struct MeetingBar: View {
    let calendar: CalendarFeature
    let event: DayEvent

    var body: some View {
        DeckSlot(needsYou: true) {
            DeckIconView(.calendar, size: 14).foregroundStyle(Deck.signal)
            Text(event.title).deckText(.body, color: Deck.signal).fontWeight(.semibold).lineLimit(1)
            Spacer(minLength: 0)
            Button("Join") { calendar.join(event) }.buttonStyle(.deck(.accent, slot: true))
        }
        .accessibilityElement(children: .contain)
    }
}

/// The add field: a line of plain words that becomes an event or a note. Return saves, Tab switches Event
/// and Note, and clicking away closes it. With Note chosen the field also offers the note's colour in five
/// dots and, as two toggles that exclude each other, a window on the desktop or on top.
struct NowAddField: View {
    let calendar: CalendarFeature?
    let notes: NotesFeature?
    @Bindable var model: NowModel

    @FocusState private var focused: Bool
    @State private var didFocus = false
    /// The slot's width, which decides whether the Event/Note control has room beside a note's options.
    @State private var slotWidth: CGFloat = .infinity
    @Environment(\.deckAccent) private var accent

    /// The width below which the control goes: at the smallest deck a note's colours and windows take the
    /// room, and Tab still switches.
    static let roomForKindControl: CGFloat = 440

    private var canEvent: Bool { calendar?.access == .granted }
    private var canNote: Bool { notes != nil }

    var body: some View {
        let kind = model.kind(canEvent: canEvent, canNote: canNote)
        DeckSlot {
            DeckIconView(.plus, size: 14).foregroundStyle(Deck.secondary)
            TextField("", text: $model.draft)
                .textFieldStyle(.plain)
                .deckText(.body)
                .focused($focused)
                .takesKeyboard(true)
                .accessibilityLabel("New item")
                .onChange(of: model.draft) { model.edited() }
                .onSubmit(save)
                .onKeyPress(.tab) {
                    model.toggleKind(canEvent: canEvent, canNote: canNote)
                    return .handled
                }
            if let problem = model.problem {
                Text(problem).deckText(.caption).lineLimit(1)
            } else if kind == .event {
                ForEach(
                    NowModel.chips(for: model.draft, on: calendar?.selectedDay), id: \.self
                ) { DeckValueChip($0) }
            } else {
                noteOptions
            }
            if canEvent, canNote, slotWidth >= Self.roomForKindControl || kind == .event {
                DeckSegmented(NowEntryKind.allCases, selection: kind, compact: true, title: \.title) {
                    model.picked = $0
                }
                .padding(.leading, 4)
            }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            slotWidth = $0
        }
        .onAppear { Task { @MainActor in focused = true } }
        .onChange(of: focused) { _, now in
            // The field loses the keyboard when the user clicks elsewhere, or another app is picked.
            if now { didFocus = true } else if didFocus, model.isAdding { model.cancel() }
        }
    }

    // MARK: Note options

    /// Five colour dots, a hairline, then Desktop and On Top.
    private var noteOptions: some View {
        HStack(spacing: 8) {
            ForEach(NowModel.noteColors) { color in dot(color) }
            Rectangle().fill(Deck.hairline).frame(width: 1, height: 18).accessibilityHidden(true)
            windowToggle(.desktop, icon: .display, label: "Desktop")
            windowToggle(.top, icon: .onTop, label: "On Top")
        }
        .accessibilityElement(children: .contain)
    }

    private func dot(_ color: NoteColor) -> some View {
        let chosen = model.noteColor == color
        return Button {
            model.pick(color)
        } label: {
            Circle()
                .fill(color.swatch)
                .frame(width: 15, height: 15)
                .padding(3.5)
                .overlay { if chosen { Circle().strokeBorder(Deck.text, lineWidth: 1.5).padding(1) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(-3.5)
        .help(color.name)
        .accessibilityLabel(color.name)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func windowToggle(_ window: NoteWindow, icon: DeckIcon, label: String) -> some View {
        let on = model.noteWindow == window
        return Button {
            model.toggle(window)
        } label: {
            DeckIconView(icon, size: 14)
                .foregroundStyle(on ? accent : Deck.secondary)
                .frame(width: 28, height: 24)
                .background(Capsule().fill(on ? accent.tint() : Deck.control))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func save() {
        model.submit(calendar: canEvent ? calendar : nil, notes: notes, day: calendar?.selectedDay)
    }
}
