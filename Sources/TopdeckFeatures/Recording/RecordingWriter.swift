// SPDX-License-Identifier: MIT
// Adapted from Snapzy (https://github.com/duongductrong/Snapzy) at 77d3d3f: Features/Recording/RecordingSession.swift.
// Copyright (c) 2026, Trong Duong Duc. BSD 3-Clause License; see THIRD_PARTY_NOTICES.md.
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// The recording's file: an MP4 written as the frames arrive, from any thread. The session starts at the first
/// video frame so the picture and the sound share a timeline, and audio before it is dropped. The movie is
/// written in fragments every few seconds, so a disk that fills up or a crash leaves a file that plays up to
/// that point and not one with no index.
final class RecordingWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let systemAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private var timeline = RecordingPauseTimeline()
    private var capturing = false
    private var sessionStarted = false
    private var firstTime: CMTime?
    private var reportedFailure = false
    private var onFirstFrame: (@Sendable () -> Void)?
    private var onFailure: (@Sendable (Error) -> Void)?

    /// Frames that reached `appendVideo`, and the ones the writer took, for tests and the log.
    private(set) var framesReceived = 0
    private(set) var framesWritten = 0

    init(url: URL, width: Int, height: Int, systemAudio: Bool, microphone: Bool) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: 4, preferredTimescale: 600)
        let video = AVAssetWriterInput(
            mediaType: .video, outputSettings: RecordingEncoding.videoSettings(width: width, height: height))
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(video)
        func audioInput() throws -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: RecordingEncoding.audioSettings())
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
            writer.add(input)
            return input
        }
        self.writer = writer
        self.video = video
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        self.systemAudio = systemAudio ? try audioInput() : nil
        self.microphone = microphone ? try audioInput() : nil
    }

    /// `first` runs when the first picture is written, `failure` once if the file can't be written any more.
    func start(first: (@Sendable () -> Void)? = nil, failure: (@Sendable (Error) -> Void)? = nil) throws {
        onFirstFrame = first
        onFailure = failure
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        lock.withLock { capturing = true }
    }

    /// Whether the encoder can take another picture now.
    var isReady: Bool { video.isReadyForMoreMediaData }

    func pause(atHostTime time: CMTime) { lock.withLock { timeline.pause(at: time) } }

    func resume(atHostTime time: CMTime) { lock.withLock { timeline.resume(at: time) } }

    // MARK: Samples

    /// A frame from ScreenCaptureKit. Only complete frames carry a picture; the rest are status updates.
    func appendVideo(_ sample: CMSampleBuffer) {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
            let pixels = CMSampleBufferGetImageBuffer(sample)
        else { return }
        appendVideo(pixels, at: CMSampleBufferGetPresentationTimeStamp(sample))
    }

    /// One picture, stamped on the capture clock.
    func appendVideo(_ pixels: CVPixelBuffer, at time: CMTime) {
        guard time.isValid else { return }
        let step: (CMTime, Bool)? = lock.withLock {
            guard capturing, writer.status == .writing, let output = timeline.acceptVideoFrame(at: time) else {
                return nil
            }
            framesReceived += 1
            defer { sessionStarted = true }
            return (output, !sessionStarted)
        }
        guard let (output, first) = step else { return reportIfFailed() }
        if first {
            writer.startSession(atSourceTime: output)
            lock.withLock { firstTime = output }
            onFirstFrame?()
        }
        guard video.isReadyForMoreMediaData else { return }  // the encoder is behind: this frame is dropped
        if adaptor.append(pixels, withPresentationTime: output) {
            lock.withLock { framesWritten += 1 }
        } else {
            reportIfFailed()
        }
    }

    func appendSystemAudio(_ sample: CMSampleBuffer) { appendAudio(sample, to: systemAudio) }

    func appendMicrophone(_ sample: CMSampleBuffer) { appendAudio(sample, to: microphone) }

    private func appendAudio(_ sample: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input, sample.isValid else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        let step: CMTime? = lock.withLock {
            guard capturing, writer.status == .writing, let first = firstTime,
                let output = timeline.outputTime(for: time), output >= first
            else { return nil }
            return timeline.accumulatedOffset
        }
        guard let offset = step, input.isReadyForMoreMediaData,
            let shifted = Self.shifted(sample, by: offset)
        else { return }
        if !input.append(shifted) { reportIfFailed() }
    }

    /// A copy of an audio buffer with its time moved back by the paused span, or the buffer itself with none.
    private static func shifted(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset.isNumeric, offset > .zero else { return sample }
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else { return nil }
        timing.presentationTimeStamp = CMTimeSubtract(timing.presentationTimeStamp, offset)
        if timing.decodeTimeStamp.isValid { timing.decodeTimeStamp = CMTimeSubtract(timing.decodeTimeStamp, offset) }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleBufferOut: &copy)
        return status == noErr ? copy : nil
    }

    /// Tells the owner once that the file can't be written any more.
    private func reportIfFailed() {
        let error: Error? = lock.withLock {
            guard writer.status == .failed, !reportedFailure else { return nil }
            reportedFailure = true
            return writer.error ?? CocoaError(.fileWriteUnknown)
        }
        if let error { onFailure?(error) }
    }

    // MARK: Finishing

    /// Closes the file. Returns the error if the writer had failed: what was written is still on disk.
    func finish() async -> Error? {
        lock.withLock { capturing = false }
        guard writer.status == .writing else { return writer.error }
        if lock.withLock({ sessionStarted }) {
            video.markAsFinished()
            systemAudio?.markAsFinished()
            microphone?.markAsFinished()
            await writer.finishWriting()
        } else {
            // No picture ever came: there is no session to close.
            writer.cancelWriting()
            return CocoaError(.fileWriteUnknown)
        }
        return writer.status == .completed ? nil : writer.error
    }

    /// Stops and throws the file away.
    func cancel() {
        lock.withLock { capturing = false }
        if writer.status == .writing { writer.cancelWriting() }
    }
}
