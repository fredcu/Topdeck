// SPDX-License-Identifier: MIT
import AppKit
import Carbon.HIToolbox
import SwiftUI
import TopdeckSurface
import UniformTypeIdentifiers

/// A video editor's window: an ordinary window in the deck's dark colours, 960 by 506 to begin with. Space plays
/// and pauses, Delete removes the picked segment, and Command-Z and Shift-Command-Z undo and redo.
@MainActor
final class VideoEditorWindow: NSObject, NSWindowDelegate {
    let model: EditorModel
    let window: NSWindow
    /// Called once the window has closed.
    var onClose: (() -> Void)?
    /// Called with the file an export made, so the Tools screen lists it.
    var onExported: ((URL) -> Void)? {
        didSet { model.onExported = onExported }
    }

    private var keyMonitor: Any?
    private static let defaultSize = CGSize(width: 960, height: 506)
    private static let minimumSize = CGSize(width: 820, height: 480)
    /// The title bar's height, which is also where the traffic lights sit.
    private static let barHeight: CGFloat = 48

    init(url: URL) {
        model = EditorModel(url: url)
        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        super.init()
        window.title = url.lastPathComponent
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Deck.body)
        window.minSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("")  // each video opens at the default size
        let root = VideoEditorView(
            model: model, reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            chooseFile: { [weak self] in self?.chooseDestination() })
        window.contentView = NSHostingView(rootView: root)
    }

    func show() {
        window.center()
        alignTrafficLights()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === window else { return event }
            return handle(event) ? nil : event
        }
        Task { await model.load() }
    }

    func close() { window.close() }

    /// Centers the traffic lights in the title bar by making the bar as tall as the board draws it.
    private func alignTrafficLights() {
        guard let bar = window.standardWindowButton(.closeButton)?.superview?.superview else { return }
        bar.frame = CGRect(
            x: 0, y: window.frame.height - Self.barHeight, width: window.frame.width, height: Self.barHeight)
    }

    func windowDidResize(_ notification: Notification) { alignTrafficLights() }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.close()
        onClose?()
    }

    /// Keys that mean something to the editor. False leaves the event to whoever is typing.
    private func handle(_ event: NSEvent) -> Bool {
        if window.firstResponder is NSText { return false }
        let command = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case kVK_Space where !command:
            model.togglePlay()
        case kVK_Delete where !command, kVK_ForwardDelete where !command:
            model.deleteSelection()
        case kVK_ANSI_Z where command:
            if event.modifierFlags.contains(.shift) { model.redo() } else { model.undo() }
        case kVK_LeftArrow where !command:
            model.seek(to: model.playhead - (event.modifierFlags.contains(.shift) ? 1 : 1 / max(model.frameRate, 1)))
        case kVK_RightArrow where !command:
            model.seek(to: model.playhead + (event.modifierFlags.contains(.shift) ? 1 : 1 / max(model.frameRate, 1)))
        default:
            return false
        }
        return true
    }

    /// Save As: a panel that starts beside the source, named as an export would be.
    private func chooseDestination() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [model.edit.export.format == .mp4 ? .mpeg4Movie : .gif]
        panel.directoryURL = model.defaultFolder()
        panel.nameFieldStringValue =
            ExportNaming.destination(
                for: model.url, format: model.edit.export.format, in: model.defaultFolder()
            ).lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url, url.standardizedFileURL != model.url.standardizedFileURL
        else { return nil }
        return url
    }
}
