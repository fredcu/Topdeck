// SPDX-License-Identifier: MIT
// Adapted from Snapzy (https://github.com/duongductrong/Snapzy) at 77d3d3f: Features/VideoEditor/Services/VideoEditorExporter.swift
// (the trim, speed and compositor-backed export it builds on).
// Copyright (c) 2026, Trong Duong Duc. BSD 3-Clause License; see THIRD_PARTY_NOTICES.md.
@preconcurrency import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

public enum VideoExportError: Error, Equatable {
    case noVideo
    case failed
}

/// Writes an edit out as a new MP4 or GIF, off the main thread: the source is read through the edit (trimmed, re-timed,
/// framed) and written in a private staging directory, which is removed when the task ends. Cancelling the task
/// stops it and leaves nothing behind. The source is never written.
public enum VideoExporter {
    /// `progress` gets 0...1 from the export's thread.
    public static func export(
        source: URL, edit: VideoEdit, cursor: CursorTrack?, to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard
            destination.resolvingSymlinksInPath().standardizedFileURL
                != source.resolvingSymlinksInPath().standardizedFileURL
        else { throw VideoExportError.failed }
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoExportError.noVideo
        }
        let size = try await video.load(.naturalSize)
        let rate = Double(try await video.load(.nominalFrameRate))
        let duration = try await asset.load(.duration).seconds
        let audioCount = try await asset.loadTracks(withMediaType: .audio).count
        let plan = ExportPlan(
            source: size, duration: duration, sourceFramesPerSecond: rate, audioTracks: audioCount, edit: edit)
        let renderer = FrameRenderer(
            layout: plan.layout, edit: edit, zoom: ZoomPlan(segments: edit.zooms, cursor: cursor))
        let prepared = try await EditComposition.build(asset: asset, plan: plan, renderer: renderer)
        try Task.checkCancellation()

        let staging = destination.deletingLastPathComponent().appending(
            path: ".topdeck-export-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let partial = staging.appending(path: destination.lastPathComponent + ".partial")
        let job = Job()
        try await withTaskCancellationHandler {
            switch plan.settings.format {
            case .mp4: try await writeMP4(prepared, plan: plan, to: partial, job: job, progress: progress)
            case .gif: try await writeGIF(prepared, plan: plan, to: partial, job: job, progress: progress)
            }
        } onCancel: {
            job.cancel()
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: destination)
        }
        progress(1)
    }

    /// What a running export can be told: stop.
    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var isCancelled: Bool { lock.withLock { stopped } }
        func cancel() { lock.withLock { stopped = true } }
    }

    // MARK: MP4

    private static func writeMP4(
        _ prepared: EditComposition.Prepared, plan: ExportPlan, to url: URL, job: Job,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let reader = try AVAssetReader(asset: prepared.composition)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [prepared.videoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.videoComposition = prepared.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !prepared.audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: prepared.audioTracks,
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: RecordingEncoding.sampleRate,
                    AVNumberOfChannelsKey: RecordingEncoding.channels, AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
            output.audioMix = prepared.audioMix
            output.audioTimePitchAlgorithm = .spectral
            reader.add(output)
            audioOutput = output
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let (width, height) = (Int(plan.layout.canvas.width), Int(plan.layout.canvas.height))
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: plan.bitrate,
                    AVVideoExpectedSourceFrameRateKey: plan.framesPerSecond,
                    AVVideoMaxKeyFrameIntervalKey: Int(plan.framesPerSecond * 2),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw VideoExportError.failed }
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: RecordingEncoding.audioSettings())
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw VideoExportError.failed }
            writer.add(input)
            audioInput = input
        }

        guard reader.startReading(), writer.startWriting() else {
            throw writer.error ?? reader.error ?? VideoExportError.failed
        }
        writer.startSession(atSourceTime: .zero)

        let total = max(plan.map.outputDuration, 0.001)
        let group = DispatchGroup()
        let failure = FirstError()
        func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderOutput, label: String, reports: Bool) {
            group.enter()
            let queue = DispatchQueue(label: "net.icuai.topdeck.editor.export.\(label)")
            let pump = Pump(input: input, output: output, writer: writer, job: job, failure: failure) {
                reports ? progress(min($0 / total, 0.999)) : ()
            }
            input.requestMediaDataWhenReady(on: queue) { [pump] in
                if pump.run() { group.leave() }
            }
        }
        pump(videoInput, videoOutput, label: "video", reports: true)
        if let audioInput, let audioOutput { pump(audioInput, audioOutput, label: "audio", reports: false) }
        await withCheckedContinuation { continuation in group.notify(queue: .global()) { continuation.resume() } }

        if job.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        if let error = failure.value {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        if reader.status == .failed { throw reader.error ?? VideoExportError.failed }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? VideoExportError.failed }
    }

    /// Feeds one input from one reader output for as long as the input takes more. Everything it holds is used
    /// from its own queue only.
    private final class Pump: @unchecked Sendable {
        private let input: AVAssetWriterInput
        private let output: AVAssetReaderOutput
        private let writer: AVAssetWriter
        private let job: Job
        private let failure: FirstError
        private let report: @Sendable (Double) -> Void
        private var finished = false

        init(
            input: AVAssetWriterInput, output: AVAssetReaderOutput, writer: AVAssetWriter, job: Job,
            failure: FirstError, report: @escaping @Sendable (Double) -> Void
        ) {
            self.input = input
            self.output = output
            self.writer = writer
            self.job = job
            self.failure = failure
            self.report = report
        }

        /// True once the input has nothing more to take: the caller leaves its group.
        func run() -> Bool {
            while input.isReadyForMoreMediaData, !finished {
                guard !job.isCancelled, failure.isEmpty, let sample = output.copyNextSampleBuffer() else {
                    return finish()
                }
                report(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                if !input.append(sample) {
                    failure.set(writer.error ?? VideoExportError.failed)
                    return finish()
                }
            }
            return false
        }

        private func finish() -> Bool {
            finished = true
            input.markAsFinished()
            return true
        }
    }

    private final class FirstError: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?
        var value: Error? { lock.withLock { error } }
        var isEmpty: Bool { lock.withLock { error == nil } }
        func set(_ new: Error) { lock.withLock { if error == nil { error = new } } }
    }

    // MARK: GIF

    private static func writeGIF(
        _ prepared: EditComposition.Prepared, plan: ExportPlan, to url: URL, job: Job,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let reader = try AVAssetReader(asset: prepared.composition)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [prepared.videoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = prepared.videoComposition
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? VideoExportError.failed }

        let count = plan.frameCount
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.gif.identifier as CFString, count, nil)
        else { throw VideoExportError.failed }
        CGImageDestinationSetProperties(
            destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frame: CFDictionary =
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 1 / plan.framesPerSecond]]
            as CFDictionary

        // This runs on the export's own thread, never the main one.
        var written = 0
        var last: CGImage?
        while written < count, !job.isCancelled, let sample = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
            guard let image else { throw VideoExportError.failed }
            CGImageDestinationAddImage(destination, image, frame)
            last = image
            written += 1
            progress(min(Double(written) / Double(count), 0.99))
        }
        // The reader can end a frame short: the last one is held, so the file holds what it promised.
        while written < count, !job.isCancelled, let last {
            CGImageDestinationAddImage(destination, last, frame)
            written += 1
        }
        if job.isCancelled {
            reader.cancelReading()
            throw CancellationError()
        }
        guard written == count, CGImageDestinationFinalize(destination) else { throw VideoExportError.failed }
    }
}
