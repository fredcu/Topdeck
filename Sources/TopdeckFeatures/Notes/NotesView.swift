// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckSurface

/// The notes tab: a list of notes beside an editor card. Hovering a note shows its pin and delete
/// buttons. The segmented control under the text says where the note shows (the notch, on the desktop,
/// or on top of other windows), and the dots next to it set its color. Search, sort, send to Tasks,
/// share and new note are in the deck's second row. Clicking into a field gives the notch keyboard
/// focus; Escape or clicking elsewhere hands it back.
struct NotesView: View {
    @Bindable var notes: NotesFeature
    @FocusState private var editorFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if notes.notes.isEmpty {
            DeckEmptyLine("No notes yet")
        } else {
            HStack(spacing: Deck.Metric.gap) {
                list.frame(width: 210)
                editor
            }
            .onAppear(perform: takeFocusIfWanted)
            .onChange(of: notes.wantsEditorFocus) { _, _ in takeFocusIfWanted() }
        }
    }

    /// Puts the cursor in the editor after the quick note shortcut, once the editor is on screen.
    private func takeFocusIfWanted() {
        guard notes.wantsEditorFocus else { return }
        Task { @MainActor in
            editorFocused = true
            notes.editorTookFocus()
        }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(notes.visibleNotes) { note in
                    NoteRow(notes: notes, note: note, isSelected: notes.selection == note.id)
                }
                if notes.visibleNotes.isEmpty {
                    Text("No matches").deckText(.caption).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: Editor

    @ViewBuilder private var editor: some View {
        if let note = notes.selected {
            DeckCard {
                VStack(alignment: .leading, spacing: Deck.Metric.gap) {
                    TextEditor(text: Binding(get: { note.text }, set: { notes.update(note.id, text: $0) }))
                        .font(DeckTextStyle.body.font)
                        .lineSpacing(4)
                        .foregroundStyle(Deck.text)
                        .scrollContentBackground(.hidden)
                        .focused($editorFocused)
                        .accessibilityLabel("Note text")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    if let notice = notes.notice {
                        Text(notice).deckText(.detail).lineLimit(1).transition(.opacity)
                    }
                    ViewThatFits(in: .horizontal) {
                        controls(note, dots: 6)
                        controls(note, dots: 4)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: notes.notice)
            }
        }
    }

    private func controls(_ note: Note, dots: CGFloat) -> some View {
        HStack(spacing: Deck.Metric.gap) {
            DeckSegmented(Placement.allCases, selection: Placement(note.window), title: \.title) {
                notes.setWindow(note.id, $0.window)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Where this note shows")
            Spacer(minLength: 0)
            HStack(spacing: dots) {
                dot(nil, note)
                ForEach(NoteColor.allCases) { dot($0, note) }
            }
        }
    }

    /// A color choice: its dot, ringed when it's the note's.
    private func dot(_ color: NoteColor?, _ note: Note) -> some View {
        let chosen = note.color == color
        return Button {
            notes.setColor(note.id, color)
        } label: {
            Circle()
                .fill(color?.swatch ?? Deck.tertiary)
                .frame(width: 9, height: 9)
                .padding(3.5)
                .overlay { if chosen { Circle().strokeBorder(Deck.text, lineWidth: 1.5) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(-3.5)
        .help(color?.name ?? "No Color")
        .accessibilityLabel(color?.name ?? "No Color")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// Where a note shows: the notch only, or a window on the desktop or on top.
    private enum Placement: CaseIterable, Hashable {
        case notch, desktop, top

        init(_ window: NoteWindow?) {
            switch window {
            case nil: self = .notch
            case .desktop?: self = .desktop
            case .top?: self = .top
            }
        }

        var window: NoteWindow? {
            switch self {
            case .notch: nil
            case .desktop: .desktop
            case .top: .top
            }
        }

        var title: String {
            switch self {
            case .notch: "Notch"
            case .desktop: "Desktop"
            case .top: "On Top"
            }
        }
    }
}

extension NotesFeature {
    /// The second row's controls: search, sort, the selected note's checklist and share, and new note.
    public var headerActions: some View { NotesActions(notes: self) }
}

struct NotesActions: View {
    @Bindable var notes: NotesFeature

    var body: some View {
        if !notes.notes.isEmpty {
            DeckSearchField("Search", text: $notes.search, width: 150)
                .padding(.trailing, 6)
            Menu {
                Picker("Sort By", selection: $notes.sort) {
                    ForEach(NoteSort.allCases) { sort in Text(sort.name).tag(sort) }
                }
                .pickerStyle(.inline)
            } label: {
                DeckIconView(.list).foregroundStyle(Deck.secondary).frame(
                    width: Deck.Metric.iconButton, height: Deck.Metric.iconButton)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort notes")
            .accessibilityLabel("Sort")
            if let note = notes.selected {
                if note.hasOpenChecklist {
                    DeckIconButton(.check, label: "Send unticked items to Tasks") { _ = notes.sendToTasks(note.id) }
                }
                ShareLink(item: note.text, subject: Text(note.title)) { DeckIconView(.share) }
                    .buttonStyle(.deckIcon())
                    .help("Share to Notes, Mail, Messages, and more")
                    .accessibilityLabel("Share")
            }
        }
        DeckIconButton(.plus, label: "New Note") { _ = notes.add() }
    }
}

extension NoteColor {
    var swatch: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        }
    }
}

/// One note in the list: its color, title, and where it shows or that it's pinned. Hovering swaps the
/// last two for pin and delete.
private struct NoteRow: View {
    let notes: NotesFeature
    let note: Note
    let isSelected: Bool

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DeckRow(selected: isSelected, action: { notes.selection = note.id }) {
            Circle().fill(note.color?.swatch ?? Deck.tertiary).frame(width: 9, height: 9)
            Text(note.title).deckText(.body).lineLimit(1)
            Spacer(minLength: 0)
            if hovering {
                HStack(spacing: 8) {
                    Button {
                        notes.togglePin(note.id)
                    } label: {
                        DeckIconView(.pin, size: 13)
                    }
                    .accessibilityLabel(note.isPinned ? "Unpin" : "Pin")
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { notes.delete(note.id) }
                    } label: {
                        DeckIconView(.trash, size: 13)
                    }
                    .accessibilityLabel("Move to Trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Deck.secondary)
            } else {
                if note.window != nil { DeckIconView(.display, size: 13).foregroundStyle(Deck.tertiary) }
                if note.isPinned { DeckIconView(.pin, size: 13).foregroundStyle(Deck.secondary) }
            }
        }
        .onHover { hovering = $0 }
        .help(tooltip)
        .onDrag {
            notes.fileURL(for: note.id).flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
        }
        .contextMenu {
            Button(note.isPinned ? "Unpin" : "Pin to Top") { notes.togglePin(note.id) }
            Menu("Window") { windowPicker }
            Picker("Color", selection: Binding(get: { note.color }, set: { notes.setColor(note.id, $0) })) {
                Text("None").tag(NoteColor?.none)
                ForEach(NoteColor.allCases) { color in Text(color.name).tag(NoteColor?.some(color)) }
            }
            .pickerStyle(.menu)
            if note.hasOpenChecklist {
                Button("Send Unticked Items to Tasks") { _ = notes.sendToTasks(note.id) }
            }
            Button("Show in Finder") {
                if let url = notes.fileURL(for: note.id) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Divider()
            Button("Move to Trash", role: .destructive) { notes.delete(note.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: note.isPinned ? "Unpin" : "Pin") { notes.togglePin(note.id) }
        .accessibilityAction(named: "Move to Trash") { notes.delete(note.id) }
        .accessibilityActions {
            ForEach(NoteWindow.allCases) { window in
                Button(window.name) { notes.setWindow(note.id, window) }
            }
            if note.window != nil {
                Button("Back to Notch") { notes.setWindow(note.id, nil) }
            }
        }
    }

    /// In the notch only, or in a window on the desktop or on top.
    private var windowPicker: some View {
        Picker("Window", selection: Binding(get: { note.window }, set: { notes.setWindow(note.id, $0) })) {
            Text("In Notch").tag(NoteWindow?.none)
            ForEach(NoteWindow.allCases) { window in Text(window.name).tag(NoteWindow?.some(window)) }
        }
        .pickerStyle(.inline)
    }

    private var tooltip: String {
        let edited = "Edited " + note.modified.formatted(date: .abbreviated, time: .shortened)
        return note.preview.isEmpty ? "\(note.title)\n\(edited)" : "\(note.title)\n\(note.preview)\n\(edited)"
    }
}
