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
/// and Note, and clicking away closes it. The icon before the text shows which it will be and switches it;
/// a note's colour and window are one small button after it, which opens a panel under the field.
struct NowAddField: View {
    let calendar: CalendarFeature?
    let notes: NotesFeature?
    @Bindable var model: NowModel

    @FocusState private var focused: Bool
    @State private var didFocus = false

    private var canEvent: Bool { calendar?.access == .granted }
    private var canNote: Bool { notes != nil }

    var body: some View {
        let kind = model.kind(canEvent: canEvent, canNote: canNote)
        DeckSlot {
            kindIcon(kind)
            TextField("", text: $model.draft)
                .textFieldStyle(.plain)
                .deckText(.body)
                .focused($focused)
                .takesKeyboard(true)
                .accessibilityLabel("New item")
                .onChange(of: model.draft) { model.edited() }
                .onSubmit(save)
                .onKeyPress(.tab) {
                    switchKind()
                    return .handled
                }
                .onKeyPress(phases: .down) { press in
                    guard press.modifiers == .command, let key = press.characters.first else { return .ignored }
                    return model.styleKey(key, kind: kind) ? .handled : .ignored
                }
            if let problem = model.problem {
                Text(problem).deckText(.caption).lineLimit(1)
            } else if kind == .event {
                ForEach(
                    NowModel.chips(for: model.draft, on: calendar?.selectedDay), id: \.self
                ) { DeckValueChip($0) }
            } else {
                NowStyleButton(model: model)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Under the style button's trailing edge: the slot is 34 high and pads 5 at the end.
            if kind == .note, model.isStylePanelOpen {
                NowStylePanel(model: model).offset(x: -5, y: 40)
            }
        }
        .onAppear { Task { @MainActor in focused = true } }
        .onChange(of: kind) { _, now in if now == .event { model.isStylePanelOpen = false } }
        .onChange(of: focused) { _, now in
            // The field loses the keyboard when the user clicks elsewhere, or another app is picked.
            if now { didFocus = true } else if didFocus, model.isAdding { model.cancel() }
        }
    }

    /// What the entry will be: a button that switches it when both are possible, otherwise just the icon.
    @ViewBuilder private func kindIcon(_ kind: NowEntryKind) -> some View {
        let icon = DeckIconView(kind == .event ? .calendar : .note, size: 14).foregroundStyle(Deck.secondary)
        if canEvent, canNote {
            let other = kind == .event ? "Note" : "Event"
            Button(action: switchKind) { icon.frame(width: 18, height: 18).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Switch to \(other)")
                .accessibilityLabel("Switch to \(other)")
        } else {
            icon.accessibilityLabel(kind.title)
        }
    }

    private func switchKind() { model.toggleKind(canEvent: canEvent, canNote: canNote) }

    private func save() {
        model.submit(calendar: canEvent ? calendar : nil, notes: notes, day: calendar?.selectedDay)
    }
}

/// A note's colour as a square: filled, or hollow for none.
private struct NowSwatch: View {
    let color: NoteColor?
    let side: CGFloat
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if let color {
            shape.fill(color.swatch).frame(width: side, height: side)
        } else {
            shape.strokeBorder(Deck.tertiary, lineWidth: 1.5).frame(width: side, height: side)
        }
    }
}

/// The one button for a note's style: its colour as a swatch, with a small badge for the window.
private struct NowStyleButton: View {
    @Bindable var model: NowModel

    var body: some View {
        let open = model.isStylePanelOpen
        Button {
            model.isStylePanelOpen.toggle()
        } label: {
            NowSwatch(color: model.noteColor, side: 16, radius: 5)
                .frame(width: 30, height: 30)
                .overlay(alignment: .bottomTrailing) { badge.padding(2) }
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(open ? Deck.control : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Colour and window (\u{2318}.)")
        .accessibilityLabel("Colour and window")
        .accessibilityValue(summary)
    }

    @ViewBuilder private var badge: some View {
        if let window = model.noteWindow {
            let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
            DeckIconView(window == .desktop ? .display : .onTop, size: 9)
                .foregroundStyle(Deck.text)
                .frame(width: 13, height: 13)
                .background(shape.fill(Deck.cardRaised))
                .overlay(shape.strokeBorder(Deck.cardRaised, lineWidth: 1.5).padding(-1.5))
        }
    }

    private var summary: String {
        let colour = model.noteColor?.name ?? "No colour"
        guard let window = model.noteWindow else { return colour }
        return colour + (window == .desktop ? ", desktop" : ", on top")
    }
}

/// The panel under the style button: the colours in a row, then None, Desktop and On Top as one control.
/// Drawn in the deck rather than as a popover, since the field closes when it loses the keyboard; its
/// buttons never take the keyboard, so choosing leaves the text field editing.
private struct NowStylePanel: View {
    @Bindable var model: NowModel
    @Environment(\.deckAccent) private var accent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                colour(nil, help: "No colour (\u{2318}0)")
                ForEach(Array(NowModel.noteColors.enumerated()), id: \.element) { index, color in
                    Spacer(minLength: 0)
                    colour(color, help: "\(color.name) (\u{2318}\(index + 1))")
                }
            }
            HStack(spacing: 2) {
                window(nil, label: "No window")
                window(.desktop, label: "Desktop")
                window(.top, label: "On Top")
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Deck.body))
        }
        .padding(12)
        .frame(width: 232)
        .background(shape.fill(Deck.cardRaised))
        .overlay(shape.strokeBorder(Deck.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 15, y: 10)
        .contentShape(shape)
        .accessibilityElement(children: .contain)
    }

    private func colour(_ color: NoteColor?, help: String) -> some View {
        let chosen = model.noteColor == color
        return Button {
            model.setColor(color)
        } label: {
            NowSwatch(color: color, side: 18, radius: 6)
                .frame(width: 28, height: 28)
                .overlay {
                    if chosen {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Deck.text, lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .accessibilityLabel(color?.name ?? "No colour")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func window(_ window: NoteWindow?, label: String) -> some View {
        let chosen = model.noteWindow == window
        return Button {
            model.setWindow(window)
        } label: {
            Group {
                switch window {
                case nil: Capsule().frame(width: 8, height: 1.5)
                case .desktop: DeckIconView(.display, size: 15)
                case .top: DeckIconView(.onTop, size: 15)
                }
            }
            .foregroundStyle(chosen ? accent : Deck.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(chosen ? accent.tint() : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
