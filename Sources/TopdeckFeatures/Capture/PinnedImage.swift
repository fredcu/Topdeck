// SPDX-License-Identifier: MIT
import AppKit
import Carbon.HIToolbox

/// A capture pinned on screen: a borderless window above other apps, on every Space. Drag it to
/// move it, scroll or pinch to zoom, double-click or press Escape to close it. Its menu copies it or
/// puts it on the Shelf.
@MainActor
final class PinnedImage: NSObject, NSWindowDelegate {
    private let capture: CaptureImage
    private let window: PinWindow
    /// Called once the window has closed.
    var onClose: (() -> Void)?

    init(capture: CaptureImage, copy: @escaping (CaptureImage) -> Void, shelve: @escaping (CaptureImage) -> Void) {
        self.capture = capture
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let center = CGPoint(x: visible.midX, y: visible.midY)
        let frame = CaptureGeometry.pinFrame(imageSize: capture.pointSize, center: center, visible: visible)
        window = PinWindow(frame: frame)
        super.init()
        let view = PinView(capture: capture)
        view.onZoom = { [weak self] factor in self?.zoom(by: factor) }
        view.onClose = { [weak self] in self?.window.close() }
        view.menu = Self.menu(
            copy: { [capture] in copy(capture) }, shelve: { [capture] in shelve(capture) },
            close: { [weak self] in self?.window.close() })
        window.contentView = view
        window.delegate = self
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private func zoom(by factor: CGFloat) {
        window.setFrame(CaptureGeometry.zoomed(window.frame, by: factor, imageSize: capture.pointSize), display: true)
    }

    private static func menu(
        copy: @escaping () -> Void, shelve: @escaping () -> Void, close: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Copy", action: copy))
        menu.addItem(ClosureMenuItem("Add to Shelf", action: shelve))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Close", action: close))
        return menu
    }
}

private final class PinWindow: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hasShadow = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
    }

    override var canBecomeKey: Bool { true }
}

private final class PinView: NSView {
    private let capture: CaptureImage
    var onZoom: ((CGFloat) -> Void)?
    var onClose: (() -> Void)?

    init(capture: CaptureImage) {
        self.capture = capture
        super.init(frame: CGRect(origin: .zero, size: capture.pointSize))
        wantsLayer = true
        layer?.contents = capture.image
        layer?.contentsGravity = .resize
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Pinned screenshot")
    }

    required init?(coder: NSCoder) { return nil }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onClose?()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 100 : event.scrollingDeltaY / 10
        onZoom?(1 + max(-0.5, min(0.5, delta)))
    }

    override func magnify(with event: NSEvent) {
        onZoom?(1 + event.magnification)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onClose?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("Not used from a nib") }

    @objc private func runAction() { run() }
}
