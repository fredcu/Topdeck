// SPDX-License-Identifier: MIT
// ZoneStream is adapted from OmniMac's ScreenshotCapture (MIT), Copyright (c) 2026 Sergi (BySergiMM); see
// THIRD_PARTY_NOTICES.md.
import AppKit
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

/// Where an area is, in values that can cross to ScreenCaptureKit's threads.
struct CaptureArea: Sendable {
    let display: CGDirectDisplayID
    /// From the display's top left, in points.
    let rect: CGRect
    let scale: CGFloat

    /// `rect` is in AppKit's global coordinates.
    @MainActor
    init?(_ rect: CGRect, on screen: NSScreen) {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard let number else { return nil }
        display = CGDirectDisplayID(number.uint32Value)
        self.rect = CaptureGeometry.displayLocal(rect, screen: screen.frame)
        scale = screen.backingScaleFactor
    }
}

enum ScreenGrab {
    enum Failure: Error { case noDisplay, noImage }

    /// Whether Topdeck may record the screen. Asks macOS the first time; macOS shows its prompt only
    /// once, so later calls just answer.
    @MainActor
    static func hasAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        return false
    }

    /// The area as it is now, at the display's full resolution, without the capture's own windows
    /// (`excluding`, by window number). Other Topdeck windows, such as pinned notes, stay in.
    static func image(of area: CaptureArea, excluding windowNumbers: [Int]) async throws -> CaptureImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == area.display }) else {
            throw Failure.noDisplay
        }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = area.rect
        let pixels = CaptureGeometry.pixels(area.rect.size, scale: area.scale)
        configuration.width = pixels.width
        configuration.height = pixels.height
        configuration.showsCursor = false
        configuration.captureResolution = .best
        let filter = filter(for: display, in: content, excluding: windowNumbers)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return CaptureImage(image: image, scale: CGFloat(image.width) / max(1, area.rect.width))
    }

    static func filter(
        for display: SCDisplay, in content: SCShareableContent, excluding windowNumbers: [Int]
    ) -> SCContentFilter {
        let excluded = CaptureGeometry.excludedWindows(windowNumbers, available: content.windows.map(\.windowID))
        let windows = content.windows.filter { excluded.contains($0.windowID) }
        return SCContentFilter(display: display, excludingWindows: windows)
    }
}

/// The area's frames from ScreenCaptureKit, only while a scrolling capture runs.
final class ZoneStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// `start` and `stop` can cross: Escape or Done before it has finished starting (which takes a few
    /// hundred milliseconds). Without this the stream came to life with no one left to stop it.
    private let lock = NSLock()
    private var stream: SCStream?
    private var stopped = false
    private let onFrame: @Sendable (CGImage) -> Void
    /// The system stopped it on its own: a display unplugged, the permission withdrawn.
    var onSystemStop: (@Sendable () -> Void)?

    init(onFrame: @escaping @Sendable (CGImage) -> Void) {
        self.onFrame = onFrame
    }

    func start(_ area: CaptureArea, excluding windowNumbers: [Int], queue: DispatchQueue) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == area.display }) else {
            throw ScreenGrab.Failure.noDisplay
        }
        // Without the frame and the progress panel.
        let filter = ScreenGrab.filter(for: display, in: content, excluding: windowNumbers)
        let configuration = SCStreamConfiguration()
        let pixels = CaptureGeometry.pixels(area.rect.size, scale: area.scale)
        configuration.sourceRect = area.rect
        configuration.width = pixels.width
        configuration.height = pixels.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.queueDepth = 6
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        let keep = lock.withLock {
            if !stopped { self.stream = stream }
            return !stopped
        }
        if !keep {
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .screen)
        }
    }

    func stop() async {
        let current = lock.withLock {
            stopped = true
            defer { stream = nil }
            return stream
        }
        try? await current?.stopCapture()
        try? current?.removeStreamOutput(self, type: .screen)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        // Stopped by us: everything's done already.
        guard !lock.withLock({ stopped }) else { return }
        onSystemStop?()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        guard let info = (attachments as? [[SCStreamFrameInfo: Any]])?.first,
            let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete
        else { return }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        if let image { onFrame(image) }
    }
}
