// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckCore
import TopdeckSurface

/// A window for each note taken out of the notch, on the desktop or on top. The windows edit the same
/// notes as the notch, so they open at launch and keep saving while `FeatureHost` has Notes stopped.
/// Moving or resizing one stores its frame for that display only; a window whose display is unplugged
/// moves to a screen that's there, and goes back when its display returns.
@MainActor
public final class PinnedNoteWindows: NSObject, NSWindowDelegate {
    private let notes: NotesFeature
    private let frames: NoteFrameStore
    private var windows: [Note.ID: PinnedNoteWindow] = [:]
    /// Set while Topdeck moves windows itself, so only the user's moves are stored.
    private var placing = false
    private var screenObserver: NSObjectProtocol?
    private var folderWatch: (folder: URL, source: any DispatchSourceFileSystemObject)?
    private var pendingReload: Task<Void, Never>?

    public init(notes: NotesFeature, defaults: UserDefaults = .standard) {
        self.notes = notes
        frames = NoteFrameStore(defaults: defaults)
    }

    /// Loads the notes that have windows and opens them, then keeps the windows in step with the notes.
    public func start() {
        notes.onDelete = { [frames] in frames.remove($0) }
        notes.loadWindowed()
        observeContinuously { [weak self] in self?.sync() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeAll() }
        }
    }

    /// Writes edits not yet saved, before quitting.
    public func stop() {
        notes.flush()
    }

    /// Opens, updates, and closes windows to match the notes that have one.
    private func sync() {
        watchFolder()
        let windowed = notes.windowed
        let ids = Set(windowed.map(\.id))
        for (id, window) in windows where !ids.contains(id) {
            window.close()
            windows[id] = nil
        }
        for (index, note) in windowed.enumerated() {
            guard let mode = note.window else { continue }
            if let window = windows[note.id] {
                window.mode = mode
                window.title = note.title
                continue
            }
            let window = PinnedNoteWindow(notes: notes, id: note.id)
            window.mode = mode
            window.title = note.title
            window.delegate = self
            windows[note.id] = window
            place(window, index: index)
            window.orderFrontRegardless()
        }
    }

    /// Reads the notes again when the folder changes, so a window shows what iCloud or a Markdown app
    /// wrote, and never saves over it. Edits not yet saved still win (`NotesFeature.load`).
    // ponytail: rereads the whole folder and sees only files replaced, not written in place, as atomic
    // saves and iCloud do. Use NSFilePresenter if a folder of thousands of notes or an editor that
    // writes in place needs it.
    private func watchFolder() {
        let folder = notes.directory
        guard folderWatch?.folder != folder else { return }
        folderWatch?.source.cancel()
        folderWatch = nil
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reloadSoon() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        folderWatch = (folder, source)
    }

    private func reloadSoon() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.notes.loadWindowed()
        }
    }

    private func placeAll() {
        for (index, note) in notes.windowed.enumerated() {
            if let window = windows[note.id] { place(window, index: index) }
        }
    }

    private func place(_ window: PinnedNoteWindow, index: Int) {
        let screens = NSScreen.screens.map { NoteScreen(id: $0.displayUUID, visibleFrame: $0.visibleFrame) }
        let entry = frames.entry(for: window.noteID)
        guard let placement = NoteWindowPlacement.place(entry, on: screens, index: index) else { return }
        placing = true
        window.setFrame(placement.frame, display: true)
        placing = false
    }

    private func record(_ notification: Notification) {
        guard !placing, let window = notification.object as? PinnedNoteWindow, let screen = window.screen else {
            return
        }
        let connected = Set(NSScreen.screens.map(\.displayUUID))
        frames.record(window.frame, on: screen.displayUUID, for: window.noteID, connected: connected)
    }

    public func windowDidMove(_ notification: Notification) { record(notification) }

    public func windowDidEndLiveResize(_ notification: Notification) { record(notification) }
}

/// A borderless panel for one note. It takes the keyboard when clicked, without bringing Topdeck
/// forward, so typing, Chinese input included, goes to its text view.
final class PinnedNoteWindow: NSPanel {
    let noteID: Note.ID

    var mode: NoteWindow = .desktop {
        didSet {
            guard mode != oldValue else { return }
            applyMode()
        }
    }

    init(notes: NotesFeature, id: Note.ID) {
        noteID = id
        super.init(
            contentRect: NSRect(origin: .zero, size: NoteWindowPlacement.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false)
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        minSize = NSSize(width: 140, height: 90)
        let content = PinnedNoteHostingView(rootView: PinnedNoteView(notes: notes, id: id))
        content.sizingOptions = []  // the user sizes the window, not the text
        contentView = content
        applyMode()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape never closes a pinned note; an input method composing text gets it first anyway.
    override func cancelOperation(_ sender: Any?) {}

    /// On the desktop: just above the icons, below every app's windows, on every Space, and left in
    /// place by Mission Control. On top: above other windows, full-screen apps included.
    private func applyMode() {
        switch mode {
        case .desktop:
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        case .top:
            level = .floating
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        }
    }
}

/// Hands the first click straight to SwiftUI, so a click into a note that isn't key starts typing.
private final class PinnedNoteHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A pinned note: its text on its paper colour. Hovering shows a bar to drag it by, with buttons to keep
/// it on the desktop, keep it on top, or send it back to the notch.
private struct PinnedNoteView: View {
    let notes: NotesFeature
    let id: Note.ID

    var body: some View {
        if let note = notes.notes.first(where: { $0.id == id }) {
            PinnedNoteSurface(
                text: Binding(get: { note.text }, set: { notes.update(id, text: $0) }), color: note.color,
                mode: note.window, setMode: { notes.setWindow(id, $0) })
        }
    }
}

/// What a pinned note looks like, apart from the notes it edits.
struct PinnedNoteSurface: View {
    @Binding var text: String
    let color: NoteColor?
    let mode: NoteWindow?
    let setMode: (NoteWindow?) -> Void
    @State private var hovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        text: Binding<String>, color: NoteColor?, mode: NoteWindow?, hovering: Bool = false,
        setMode: @escaping (NoteWindow?) -> Void
    ) {
        _text = text
        self.color = color
        self.mode = mode
        self.setMode = setMode
        _hovering = State(initialValue: hovering)
    }

    var body: some View {
        ZStack(alignment: .top) {
            TextEditor(text: $text)
                .font(.system(size: 13))
                .lineSpacing(4.5)
                .scrollContentBackground(.hidden)
                .foregroundStyle(Deck.Paper.ink)
                .tint(Deck.Paper.ink)
                .accessibilityLabel("Note text")
                .padding(.top, hovering ? 40 : 12)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            if hovering {
                controls.transition(.opacity)
            }
        }
        .background(color?.paper ?? Deck.Paper.plain)
        .clipShape(RoundedRectangle(cornerRadius: Deck.Floating.noteRadius, style: .continuous))
        .environment(\.colorScheme, .light)
        .onHover { inside in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { hovering = inside }
        }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            WindowDragArea()
            ForEach(NoteWindow.allCases) { option in
                barButton(option.icon, label: option.name, on: mode == option) { setMode(option) }
            }
            barButton(.arrowUpRight, label: "Back to Notch", on: false) { setMode(nil) }
        }
        .padding(.horizontal, 4)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Deck.Paper.bar))
        .padding(.top, 8)
        .padding(.horizontal, 8)
    }

    private func barButton(_ icon: DeckIcon, label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DeckIconView(icon, size: 13)
                .foregroundStyle(on ? Deck.Paper.iconOn : Deck.Paper.icon)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Deck.Paper.barOn : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Empty space that drags the window, since it has no title bar.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

extension NoteWindow {
    var name: String {
        switch self {
        case .desktop: "On Desktop"
        case .top: "Always on Top"
        }
    }

    /// The SF Symbol the notch's note list uses.
    var symbol: String {
        switch self {
        case .desktop: "menubar.dock.rectangle"
        case .top: "rectangle.stack"
        }
    }

    var icon: DeckIcon {
        switch self {
        case .desktop: .display
        case .top: .pin
        }
    }
}

extension NoteColor {
    /// The note's paper: a light colour in every appearance, since it sits on the desktop.
    var paper: Color {
        switch self {
        case .red: Deck.Paper.red
        case .orange: Deck.Paper.orange
        case .yellow: Deck.Paper.yellow
        case .green: Deck.Paper.green
        case .mint: Deck.Paper.mint
        case .blue: Deck.Paper.blue
        case .purple: Deck.Paper.purple
        case .pink: Deck.Paper.pink
        }
    }
}
