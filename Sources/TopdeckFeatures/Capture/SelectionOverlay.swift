// SPDX-License-Identifier: MIT
import AppKit
import Carbon.HIToolbox
import TopdeckSurface

/// Dims the screen under the pointer and lets the user drag out an area on it. Escape, or a click
/// without a drag, cancels.
@MainActor
final class SelectionOverlay {
    private var window: SelectionWindow?
    private var completion: ((CGRect, NSScreen, Int) -> Void)?
    /// The app in front before the overlay took the keyboard, which gets it back: it's the one a
    /// scrolling capture scrolls.
    private var previousApp: NSRunningApplication?

    var isActive: Bool { window != nil }

    /// Calls `completion` with the area in AppKit's global coordinates, its screen and the overlay's own
    /// window number, to leave out of the capture, or never when cancelled.
    func begin(completion: @escaping (CGRect, NSScreen, Int) -> Void) {
        guard window == nil else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        self.completion = completion
        let window = SelectionWindow(screen: screen)
        window.onFinish = { [weak self] rect in self?.finish(rect, on: screen) }
        self.window = window
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func finish(_ rect: CGRect?, on screen: NSScreen) {
        let number = window?.windowNumber ?? 0
        window?.orderOut(nil)
        window = nil
        if previousApp != NSRunningApplication.current { previousApp?.activate() }
        previousApp = nil
        let completion = self.completion
        self.completion = nil
        guard let rect else { return }
        completion?(rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY), screen, number)
    }
}

/// A borderless window over the whole screen that takes the keyboard for Escape.
private final class SelectionWindow: NSWindow {
    var onFinish: ((CGRect?) -> Void)?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.onFinish = { [weak self] rect in self?.onFinish?(rect) }
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var selection = CGRect.zero {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if CaptureGeometry.isArea(selection) {
            dim.append(NSBezierPath(rect: selection))
            dim.windingRule = .evenOdd
        }
        NSColor(Deck.deck).withAlphaComponent(0.35).setFill()
        dim.fill()
        guard CaptureGeometry.isArea(selection) else { return }
        NSColor(Deck.text).setStroke()
        let outline = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        outline.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CaptureGeometry.selection(from: start, to: point, in: bounds)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        start = nil
        onFinish?(CaptureGeometry.isArea(selection) ? selection : nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onFinish?(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
