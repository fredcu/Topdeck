// SPDX-License-Identifier: MIT
// Adapted from OmniMac's ScreenshotCapture (MIT), Copyright (c) 2026 Sergi (BySergiMM); see THIRD_PARTY_NOTICES.md.
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A scrolling capture in progress. **The user scrolls**, at their own pace: Topdeck moves nothing,
/// takes the area 30 times a second, stitches what passes through it, and stops at Done. Cancel or
/// Escape throws it away.
@MainActor
final class ScrollingSession {
    /// A cap: an endless feed has no end.
    static let maxPixelHeight = 20_000

    private let area: CaptureArea
    private let rect: CGRect
    private let screen: NSScreen
    private let tracker: ScrollTracker
    private let status = ScrollingStatus()
    private var zone: ZoneStream?
    private var done = false
    private var border: NSWindow?
    private var panel: NSPanel?
    private var monitors: [Any] = []
    /// The stitched capture, or nil when cancelled or nothing could be stitched.
    private let onFinish: (CaptureImage?) -> Void

    init(area: CaptureArea, rect: CGRect, screen: NSScreen, onFinish: @escaping (CaptureImage?) -> Void) {
        self.area = area
        self.rect = rect
        self.screen = screen
        self.onFinish = onFinish
        // The overlay scroll bar is about 16 points wide.
        tracker = ScrollTracker(scrollbarPixels: Int(16 * screen.backingScaleFactor))
    }

    func start() {
        showChrome()
        tracker.onProgress = { [weak self, status] pixels, lost in
            Task { @MainActor in
                status.pixels = pixels
                status.lost = lost
                if pixels >= Self.maxPixelHeight { self?.finish() }
            }
        }
        let tracker = self.tracker
        let zone = ZoneStream { [weak tracker] image in tracker?.ingest(image) }
        // If the system stops the recording, what there is gets stitched, rather than leaving the
        // panel waiting for a Done that can't add anything.
        zone.onSystemStop = { [weak self] in
            Task { @MainActor in self?.finish() }
        }
        self.zone = zone
        Task {
            do {
                try await zone.start(area, queue: tracker.queue)
            } catch {
                guard !done else { return }
                cancel()
            }
        }
    }

    /// Done: stitches what there is.
    func finish() {
        guard !done else { return }
        done = true
        let tracker = self.tracker
        let zone = self.zone
        let scale = area.scale
        Task {
            await zone?.stop()
            // Whatever is left in the tracker's queue, then the stitching, right there.
            let image: CaptureImage? = await withCheckedContinuation { continuation in
                tracker.queue.async {
                    let image = tracker.compose().map { CaptureImage(image: $0, scale: scale) }
                    tracker.discard()
                    continuation.resume(returning: image)
                }
            }
            hideChrome()
            onFinish(image)
        }
    }

    /// Cancel or Escape: nothing is kept.
    func cancel() {
        guard !done else { return }
        done = true
        let zone = self.zone
        let tracker = self.tracker
        Task { await zone?.stop() }
        tracker.queue.async { tracker.discard() }
        hideChrome()
        onFinish(nil)
    }

    // MARK: Frame and panel

    private func showChrome() {
        // A frame around the area that takes neither clicks nor the wheel.
        let frame = NSWindow(
            contentRect: rect.insetBy(dx: -3, dy: -3), styleMask: .borderless, backing: .buffered, defer: false)
        frame.isOpaque = false
        frame.backgroundColor = .clear
        frame.ignoresMouseEvents = true
        frame.level = .statusBar
        frame.collectionBehavior = [.canJoinAllSpaces, .transient]
        frame.isReleasedWhenClosed = false
        let outline = NSView(frame: CGRect(origin: .zero, size: frame.frame.size))
        outline.wantsLayer = true
        outline.layer?.borderColor = NSColor.controlAccentColor.cgColor
        outline.layer?.borderWidth = 2
        outline.layer?.cornerRadius = 4
        frame.contentView = outline
        frame.orderFrontRegardless()
        border = frame

        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 40), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.isReleasedWhenClosed = false
        let hud = ScrollingHUD(
            status: status, done: { [weak self] in self?.finish() }, cancel: { [weak self] in self?.cancel() })
        let host = NSHostingView(rootView: hud)
        panel.contentView = host
        let size = host.fittingSize
        // Below the area when it fits; otherwise above.
        let below = rect.minY - size.height - 10
        let visible = screen.visibleFrame
        let y = below > visible.minY ? below : min(rect.maxY + 10, visible.maxY - size.height)
        panel.setFrame(CGRect(origin: CGPoint(x: rect.midX - size.width / 2, y: y), size: size), display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        // When the user scrolls (to tell which frames are clean), and Escape to cancel. Global: the
        // app in front is the one scrolling. Not Return: in a chat it would send the message.
        let tracker = self.tracker
        let wheel = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { _ in
            let now = Date()
            tracker.queue.async { tracker.lastScrollAt = now }
        }
        let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            Task { @MainActor in self?.cancel() }
        }
        monitors = [wheel, keys].compactMap { $0 }
    }

    private func hideChrome() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        border?.orderOut(nil)
        panel?.orderOut(nil)
        border = nil
        panel = nil
    }
}

/// What the panel shows while capturing: how far it got.
@MainActor
@Observable
private final class ScrollingStatus {
    var pixels = 0
    /// No frame has matched for a while: the user should scroll back a little.
    var lost = false
}

private struct ScrollingHUD: View {
    let status: ScrollingStatus
    let done: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.lost ? "exclamationmark.triangle.fill" : "arrow.up.and.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(status.lost ? Color.orange : .white.opacity(0.85))
            Text(status.lost ? "Scroll back a little" : "Scroll through the area")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text("\(status.pixels) px")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            Button("Cancel", action: cancel)
                .controlSize(.small)
            Button("Done", action: done)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.8)))
        .fixedSize()
        .environment(\.colorScheme, .dark)
    }
}
