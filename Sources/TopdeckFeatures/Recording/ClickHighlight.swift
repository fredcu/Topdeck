// SPDX-License-Identifier: MIT
// Adapted from Snapzy (https://github.com/duongductrong/Snapzy) at 77d3d3f: Features/Recording/Managers/MouseClickHighlightWindow.swift,
// Services/Capture/MouseClickHighlightService.swift.
// Copyright (c) 2026, Trong Duong Duc. BSD 3-Clause License; see THIRD_PARTY_NOTICES.md.
import AppKit
import QuartzCore
import TopdeckSurface

/// A click-through window over the recorded display that draws a ring where each click lands. The recording
/// leaves it in the picture (the one Topdeck window it keeps), so the rings are part of the video.
@MainActor
final class ClickHighlight {
    private var window: ClickWindow?
    private var monitor: Any?

    /// The window number the recording keeps, once the overlay is up.
    var windowNumber: CGWindowID? { window.map { CGWindowID($0.windowNumber) } }

    func start(on screen: NSScreen) {
        guard window == nil else { return }
        let window = ClickWindow(screen: screen)
        window.orderFrontRegardless()
        self.window = window
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.window?.ring(at: point) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window?.orderOut(nil)
        window = nil
    }
}

private final class ClickWindow: NSWindow {
    private static let diameter: CGFloat = 52
    private static let duration: CFTimeInterval = 0.6

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// An orange ring that grows and fades where `point` (global) is, if that is on this display.
    func ring(at point: CGPoint) {
        guard frame.contains(point), let host = contentView?.layer else { return }
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        let side = Self.diameter
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: local.x - side / 2, y: local.y - side / 2, width: side, height: side)
        ring.path = CGPath(ellipseIn: CGRect(x: 2, y: 2, width: side - 4, height: side - 4), transform: nil)
        ring.fillColor = NSColor(Deck.Accent.tools).withAlphaComponent(0.28).cgColor
        ring.strokeColor = NSColor(Deck.Accent.tools).cgColor
        ring.lineWidth = 3
        ring.opacity = 0
        host.addSublayer(ring)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3
        grow.toValue = 1
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0]
        fade.keyTimes = [0, 0.2, 1]
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = Self.duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "click")
        CATransaction.commit()
    }
}
