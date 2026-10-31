// SPDX-License-Identifier: MIT
import AppKit
import Carbon.HIToolbox
import TopdeckSurface

/// A window that can be picked: its number and where it is, in AppKit's global coordinates.
struct PickableWindow: Equatable, Sendable {
    let id: CGWindowID
    let frame: CGRect
}

extension CaptureGeometry {
    /// The front-most of `windows` (listed front to back) under `point`.
    static func windowAt(_ point: CGPoint, in windows: [PickableWindow]) -> PickableWindow? {
        windows.first { $0.frame.contains(point) }
    }

    /// A rectangle from Core Graphics' window list (top left of the main display) in AppKit's global
    /// coordinates (bottom left of it).
    static func appKitFrame(_ rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Dims the screen under the pointer and outlines the window it is over; a click picks that window.
/// Escape cancels. Only window numbers and frames are read, never their contents.
@MainActor
final class WindowPicker {
    private var window: PickerWindow?
    private var previousApp: NSRunningApplication?

    var isActive: Bool { window != nil }

    /// Calls `completion` with the picked window and the overlay's own window number, or never when cancelled.
    func begin(completion: @escaping (PickableWindow, NSScreen, Int) -> Void) {
        guard window == nil else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let picker = PickerWindow(screen: screen, windows: Self.pickable())
        picker.onFinish = { [weak self] picked in
            let number = picker.windowNumber
            picker.orderOut(nil)
            self?.window = nil
            if let previous = self?.previousApp, previous != NSRunningApplication.current { previous.activate() }
            self?.previousApp = nil
            if let picked { completion(picked, screen, number) }
        }
        window = picker
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        picker.makeKeyAndOrderFront(nil)
    }

    /// The ordinary windows on screen, front to back, without Topdeck's own.
    private static func pickable() -> [PickableWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        let height = NSScreen.screens.first?.frame.height ?? 0
        let me = ProcessInfo.processInfo.processIdentifier
        return (list as? [[String: Any]] ?? []).compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0, (info[kCGWindowOwnerPID as String] as? Int32) != me,
                (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                let number = info[kCGWindowNumber as String] as? UInt32,
                let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({
                    CGRect(dictionaryRepresentation: $0 as CFDictionary)
                }), bounds.width >= 40, bounds.height >= 40
            else { return nil }
            return PickableWindow(id: number, frame: CaptureGeometry.appKitFrame(bounds, mainDisplayHeight: height))
        }
    }
}

private final class PickerWindow: NSWindow {
    var onFinish: ((PickableWindow?) -> Void)?

    init(screen: NSScreen, windows: [PickableWindow]) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        let view = PickerView(frame: CGRect(origin: .zero, size: screen.frame.size), origin: screen.frame.origin)
        view.windows = windows
        view.onFinish = { [weak self] picked in self?.onFinish?(picked) }
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

private final class PickerView: NSView {
    var onFinish: ((PickableWindow?) -> Void)?
    var windows: [PickableWindow] = []
    /// The screen's corner in global coordinates, to turn the view's points into global ones.
    let origin: CGPoint
    private var hovered: PickableWindow? {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }

    init(frame: CGRect, origin: CGPoint) {
        self.origin = origin
        super.init(frame: frame)
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func global(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x + origin.x, y: point.y + origin.y)
    }

    override func mouseMoved(with event: NSEvent) { hovered = CaptureGeometry.windowAt(global(event), in: windows) }

    override func mouseDown(with event: NSEvent) {
        hovered = CaptureGeometry.windowAt(global(event), in: windows)
        if let hovered { onFinish?(hovered) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Deck.deck).withAlphaComponent(0.35).setFill()
        bounds.fill()
        guard let hovered else { return }
        let frame = hovered.frame.offsetBy(dx: -origin.x, dy: -origin.y)
        NSColor.clear.setFill()
        frame.fill(using: .copy)
        NSColor(Deck.Accent.tools).setStroke()
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        outline.lineWidth = 2
        outline.stroke()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { onFinish?(nil) } else { super.keyDown(with: event) }
    }
}
