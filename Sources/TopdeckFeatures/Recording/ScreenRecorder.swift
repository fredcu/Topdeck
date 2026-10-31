// SPDX-License-Identifier: MIT
// Adapted from Snapzy (https://github.com/duongductrong/Snapzy) at 77d3d3f: Services/Capture/ScreenRecordingManager.swift.
// Copyright (c) 2026, Trong Duong Duc. BSD 3-Clause License; see THIRD_PARTY_NOTICES.md.
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import TopdeckCore

/// What the controller needs from whatever records, so a test can stand in for the screen.
@MainActor
protocol RecordingEngine: AnyObject {
    /// Called on the main actor, once, when the recording can't go on. The file is still to be closed with `stop()`.
    var onFailure: ((RecordingFailure) -> Void)? { get set }
    /// Called when the first picture is written.
    var onFirstFrame: (() -> Void)? { get set }
    func start() async throws
    func pause()
    func resume()
    /// Closes the file and puts it where it belongs. Nil when nothing was recorded.
    func stop() async -> URL?
}

/// ScreenCaptureKit's callbacks, off the main actor: pictures and sound straight into the writer.
private final class StreamSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let writer: RecordingWriter
    private let lock = NSLock()
    private var stopped = false
    var onStop: (@Sendable (Error) -> Void)?

    init(writer: RecordingWriter) { self.writer = writer }

    func markStopped() { lock.withLock { stopped = true } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen: writer.appendVideo(sampleBuffer)
        case .audio: writer.appendSystemAudio(sampleBuffer)
        default: break
        }
    }

    /// The system ended the stream: a display unplugged, the permission withdrawn, a window gone.
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        guard !lock.withLock({ stopped }) else { return }
        onStop?(error)
    }
}

/// Records a display or a window with ScreenCaptureKit into an MP4. Topdeck's own windows stay out of the
/// picture, apart from the ring that marks clicks.
@MainActor
final class ScreenRecorder: RecordingEngine {
    var onFailure: ((RecordingFailure) -> Void)?
    var onFirstFrame: (() -> Void)?

    private let target: RecordingTarget
    private let options: RecordingOptions
    private let destination: URL
    private let clickWindow: CGWindowID?
    private var partial: URL { destination.appendingPathExtension("partial") }
    private var stream: SCStream?
    private var sink: StreamSink?
    private var microphone: MicrophoneCapturer?
    private var reported = false

    /// `options.microphone` must already be allowed. `clickWindow` is the window that marks clicks, which stays
    /// in the picture.
    init(target: RecordingTarget, options: RecordingOptions, destination: URL, clickWindow: CGWindowID?) {
        self.target = target
        self.options = options
        self.destination = destination
        self.clickWindow = clickWindow
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        switch target {
        case .screen(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw RecordingFailure.displayGone
            }
            let me = ProcessInfo.processInfo.processIdentifier
            let own = content.applications.filter { $0.processID == me }
            let kept = content.windows.filter { $0.windowID == clickWindow }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: kept)
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw RecordingFailure.windowClosed
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)
        let size = RecordingEncoding.fittedSize(
            width: Int((info.contentRect.width * scale).rounded()),
            height: Int((info.contentRect.height * scale).rounded()))

        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(RecordingEncoding.framesPerSecond))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.queueDepth = 8
        configuration.captureResolution = .best
        if options.systemAudio {
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = RecordingEncoding.sampleRate
            configuration.channelCount = RecordingEncoding.channels
        }

        try? FileManager.default.removeItem(at: partial)
        let writer = try RecordingWriter(
            url: partial, width: size.width, height: size.height, systemAudio: options.systemAudio,
            microphone: options.microphone)
        let sink = StreamSink(writer: writer)
        sink.onStop = { [weak self] error in
            Task { @MainActor in self?.fail(error) }
        }
        try writer.start(
            first: { [weak self] in Task { @MainActor in self?.onFirstFrame?() } },
            failure: { [weak self] error in Task { @MainActor in self?.fail(error) } })

        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        let queue = DispatchQueue(label: "net.icuai.topdeck.recording.video", qos: .userInteractive)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: queue)
        if options.systemAudio {
            try stream.addStreamOutput(
                sink, type: .audio, sampleHandlerQueue: DispatchQueue(label: "net.icuai.topdeck.recording.audio"))
        }
        self.stream = stream
        self.sink = sink
        do {
            try await stream.startCapture()
        } catch {
            sink.markStopped()
            writer.cancel()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        if options.microphone {
            let capturer = MicrophoneCapturer { [weak writer] in writer?.appendMicrophone($0) }
            if capturer.start() { microphone = capturer }
        }
    }

    func pause() { sink?.writer.pause(atHostTime: CMClockGetTime(CMClockGetHostTimeClock())) }

    func resume() { sink?.writer.resume(atHostTime: CMClockGetTime(CMClockGetHostTimeClock())) }

    func stop() async -> URL? {
        sink?.markStopped()
        microphone?.stop()
        microphone = nil
        try? await stream?.stopCapture()
        stream = nil
        _ = await sink?.writer.finish()
        sink = nil
        // A file that never got a picture is nothing to keep.
        let size = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: partial)
            return nil
        }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            Log.features.error("Couldn't name a recording: \(error.localizedDescription, privacy: .public)")
            return partial
        }
        return destination
    }

    /// Tells the controller once, from either the stream or the writer.
    private func fail(_ error: Error) {
        guard !reported else { return }
        reported = true
        let hasAccess = CGPreflightScreenCaptureAccess()
        var windowExists = true
        if case .window(let id) = target { windowExists = RecordingWindows.frame(of: id) != nil }
        let failure = (error as? RecordingFailure) ?? .classify(error, hasAccess: hasAccess, windowExists: windowExists)
        Log.features.error("Recording ended: \(error.localizedDescription, privacy: .public)")
        onFailure?(failure)
    }
}

/// Where a window is, in AppKit's global coordinates; nil once the window is gone.
enum RecordingWindows {
    static func frame(of id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
            let info = list.first,
            let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({
                CGRect(dictionaryRepresentation: $0 as CFDictionary)
            })
        else { return nil }
        let height = CGDisplayBounds(CGMainDisplayID()).height
        return CaptureGeometry.appKitFrame(bounds, mainDisplayHeight: height)
    }
}
