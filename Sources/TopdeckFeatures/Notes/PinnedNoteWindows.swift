// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckCore
import TopdeckSurface

/// A window for each note taken out of the notch, on the desktop or on top, and for a note opened from Now's
/// list, which floats on top until it is closed and has no window of its own in the file. The windows edit
/// the same notes as the notch, so they open at launch and keep saving while `FeatureHost` has Notes stopped.
/// Moving or resizing one stores its frame for that display only; a window whose display is unplugged
/// moves to a screen that's there, and goes back when its display returns.
@MainActor
public final class PinnedNoteWindows: NSObject, NSWindowDelegate {
    private let notes: NotesFeature
    private let frames: NoteFrameStore
    private var windows: [Note.ID: PinnedNoteWindow] = [:]
    /// Windows of notes opened from the list, which close without the note losing anything.
    private var opened: Set<Note.ID> = []
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

    /// Opens a note in a floating window to read and edit, or brings its window forward when it has one.
    /// Closing the window keeps the note.
    public func present(_ id: Note.ID) {
        if bringForward(id) { return }
        guard notes.notes.contains(where: { $0.id == id }) else { return }
        notes.held.insert(id)
        opened.insert(id)
        let window = makeWindow(for: id, mode: .top)
        window.isOpenedFromList = true
        place(window, index: windows.count)
        window.present()
    }

    /// Brings a note's window forward and gives it the keyboard; false when it has none.
    // ponytail: a desktop note stays below other apps' windows, as its level says; it comes in front of
    // other desktop notes only. Raise it to the floating level for a moment if that isn't enough.
    @discardableResult
    public func bringForward(_ id: Note.ID) -> Bool {
        guard let window = windows[id] else { return false }
        window.present()
        return true
    }

    /// Opens, updates, and closes windows to match the notes that have one.
    private func sync() {
        watchFolder()
        let windowed = notes.windowed
        let ids = Set(windowed.map(\.id))
        let existing = Set(notes.notes.map(\.id))
        // A note opened from the list stays open until its window closes or the note is gone.
        for (id, window) in windows where !ids.contains(id) && !(opened.contains(id) && existing.contains(id)) {
            forget(id)
            window.close()
        }
        for (index, note) in windowed.enumerated() {
            guard let mode = note.window else { continue }
            if let window = windows[note.id] {
                // A note opened from the list that was then pinned keeps its window, now as a pinned one.
                if opened.remove(note.id) != nil {
                    window.isOpenedFromList = false
                    notes.held.remove(note.id)
                }
                window.mode = mode
                window.title = note.title
                continue
            }
            let window = makeWindow(for: note.id, mode: mode)
            window.title = note.title
            place(window, index: index)
            window.orderFrontRegardless()
        }
        for id in opened { windows[id]?.title = notes.notes.first { $0.id == id }?.title ?? "" }
    }

    private func makeWindow(for id: Note.ID, mode: NoteWindow) -> PinnedNoteWindow {
        let window = PinnedNoteWindow(notes: notes, id: id) { [weak self] in self?.closeOpened(id) }
        window.mode = mode
        window.title = notes.notes.first { $0.id == id }?.title ?? ""
        window.delegate = self
        windows[id] = window
        return window
    }

    /// The close button of a note opened from the list: the window goes, the note stays.
    private func closeOpened(_ id: Note.ID) {
        guard opened.contains(id) else { return }
        windows[id]?.close()
        forget(id)
    }

    private func forget(_ id: Note.ID) {
        windows[id] = nil
        opened.remove(id)
        notes.held.remove(id)
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
            // Topdeck's own saves change the folder too; only another app's change is read back.
            guard let notes = self?.notes, notes.folderChanged() else { return }
            notes.loadWindowed()
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
        // A note opened from the list has no window of its own to remember.
        guard !placing, let window = notification.object as? PinnedNoteWindow, !window.isOpenedFromList,
            let screen = window.screen
        else {
            return
        }
        let connected = Set(NSScreen.screens.map(\.displayUUID))
        frames.record(window.frame, on: screen.displayUUID, for: window.noteID, connected: connected)
    }

    public func windowDidMove(_ notification: Notification) { record(notification) }

    public func windowDidEndLiveResize(_ notification: Notification) { record(notification) }

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? PinnedNoteWindow, window.isOpenedFromList else { return }
        forget(window.noteID)
    }
}

/// A borderless panel for one note. It takes the keyboard when clicked or opened on purpose, without bringing
/// Topdeck forward, so typing, Chinese input included, goes to its text view. It never takes the keyboard
/// otherwise, such as when the deck or the Command Bar closes while another app is in front.
final class PinnedNoteWindow: NSPanel {
    let noteID: Note.ID
    private var keyPolicy = NoteKeyPolicy()
    /// Opened from Now's list rather than pinned: Escape and the bar's close button close it.
    var isOpenedFromList = false

    var mode: NoteWindow = .desktop {
        didSet {
            guard mode != oldValue else { return }
            applyMode()
        }
    }

    init(notes: NotesFeature, id: Note.ID, close: @escaping () -> Void) {
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
        let content = PinnedNoteHostingView(rootView: PinnedNoteView(notes: notes, id: id, close: close))
        content.sizingOptions = []  // the user sizes the window, not the text
        contentView = content
        applyMode()
    }

    override var canBecomeKey: Bool { keyPolicy.canBecomeKey }
    override var canBecomeMain: Bool { false }

    /// Brings the window forward and gives it the keyboard: the user opened it.
    func present() {
        keyPolicy.present()
        orderFrontRegardless()
        makeKey()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            keyPolicy.mouseDown()
            if !isKeyWindow { makeKey() }
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        keyPolicy.resign()
        super.resignKey()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        guard flags == .command || flags == [.command, .shift], let key = event.charactersIgnoringModifiers,
            let action = NoteKeyPolicy.editingAction(for: key, shift: flags.contains(.shift))
        else {
            return false
        }
        return NSApp.sendAction(action, to: nil, from: self)
    }

    /// Escape never closes a pinned note, but it closes one opened from the list; an input method
    /// composing text gets it first anyway.
    override func cancelOperation(_ sender: Any?) {
        if isOpenedFromList { close() }
    }

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
    let close: () -> Void

    var body: some View {
        if let note = notes.notes.first(where: { $0.id == id }) {
            PinnedNoteSurface(
                // Reads the model when asked, not the value at this render, so a later render never hands the
                // editor older text than it has.
                text: Binding(
                    get: { notes.notes.first { $0.id == id }?.text ?? note.text }, set: { notes.update(id, text: $0) }),
                color: note.color,
                mode: note.window, setMode: { notes.setWindow(id, $0) }, close: note.window == nil ? close : nil)
        }
    }
}

/// What a pinned note looks like, apart from the notes it edits.
struct PinnedNoteSurface: View {
    @Binding var text: String
    let color: NoteColor?
    let mode: NoteWindow?
    let setMode: (NoteWindow?) -> Void
    /// Closes the window of a note opened from the list; nil for a pinned note, which is unpinned instead.
    let close: (() -> Void)?
    @State private var hovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        text: Binding<String>, color: NoteColor?, mode: NoteWindow?, hovering: Bool = false,
        setMode: @escaping (NoteWindow?) -> Void, close: (() -> Void)? = nil
    ) {
        self.close = close
        _text = text
        self.color = color
        self.mode = mode
        self.setMode = setMode
        _hovering = State(initialValue: hovering)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // The bar sits over the strip above the text, so hovering moves nothing in the editor.
            NoteTextEditor(text: $text)
                .padding(.top, 30)
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
            if let close {
                barButton(.close, label: "Close", on: false, action: close)
            } else {
                barButton(.arrowUpRight, label: "Back to Notch", on: false) { setMode(nil) }
            }
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
    /// The colour of the note's square in Now's list and of the dot that picks it.
    public var swatch: Color {
        switch self {
        case .red: Deck.Note.red
        case .orange: Deck.Note.orange
        case .yellow: Deck.Note.yellow
        case .green: Deck.Note.green
        case .mint: Deck.Note.mint
        case .blue: Deck.Note.blue
        case .purple: Deck.Note.purple
        case .pink: Deck.Note.pink
        }
    }

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
