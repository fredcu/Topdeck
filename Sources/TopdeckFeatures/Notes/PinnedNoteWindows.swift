// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckCore

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
        let screens = NSScreen.screens.map { NoteScreen(id: $0.noteDisplayID, visibleFrame: $0.visibleFrame) }
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
        let connected = Set(NSScreen.screens.map(\.noteDisplayID))
        frames.record(window.frame, on: screen.noteDisplayID, for: window.noteID, connected: connected)
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

/// A pinned note: its text on its colour. Hovering shows a bar to drag it by, with buttons to keep it
/// on the desktop, keep it on top, or send it back to the notch.
private struct PinnedNoteView: View {
    let notes: NotesFeature
    let id: Note.ID
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let note = notes.notes.first(where: { $0.id == id }) {
            ZStack(alignment: .top) {
                TextEditor(text: Binding(get: { note.text }, set: { notes.update(id, text: $0) }))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("Note text")
                    .padding(.top, 22)
                    .padding([.horizontal, .bottom], 8)
                if hovering {
                    controls(note).transition(.opacity)
                }
            }
            .background {
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    Rectangle().fill(note.color?.swatch.opacity(0.3) ?? .clear)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onHover { inside in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { hovering = inside }
            }
        }
    }

    private func controls(_ note: Note) -> some View {
        HStack(spacing: 8) {
            WindowDragArea()
            ForEach(NoteWindow.allCases) { mode in
                Button {
                    notes.setWindow(id, mode)
                } label: {
                    Image(systemName: mode.symbol).opacity(note.window == mode ? 1 : 0.5)
                }
                .help(mode.name)
                .accessibilityLabel(mode.name)
                .accessibilityAddTraits(note.window == mode ? .isSelected : [])
            }
            Button {
                notes.setWindow(id, nil)
            } label: {
                Image(systemName: "arrow.up.to.line")
            }
            .help("Back to Notch")
            .accessibilityLabel("Back to Notch")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
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

    var symbol: String {
        switch self {
        case .desktop: "menubar.dock.rectangle"
        case .top: "rectangle.stack"
        }
    }
}

extension NSScreen {
    /// The display's UUID, which, unlike its number, stays the same across reconnects and restarts.
    fileprivate var noteDisplayID: String {
        let number = (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return "\(number)" }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
