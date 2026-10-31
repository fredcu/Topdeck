// SPDX-License-Identifier: MIT
// Adapted from Snapzy (https://github.com/duongductrong/Snapzy) at 77d3d3f: Features/VideoEditor/Services/VideoEditorZoomCompositor.swift.
// Copyright (c) 2026, Trong Duong Duc. BSD 3-Clause License; see THIRD_PARTY_NOTICES.md.
@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

/// Draws one frame of the edit: the source cropped, zoomed to where the camera is, rounded and laid over its
/// background. The preview and the export both use it, so what is seen is what is written.
public final class FrameRenderer: @unchecked Sendable {
    public let layout: FrameLayout
    public let zoom: ZoomPlan
    private let background: CIImage?
    private let cornerMask: CIImage?
    /// One for every renderer: making a context is slow, and the preview makes a renderer for each change.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    public init(layout: FrameLayout, edit: VideoEdit, zoom: ZoomPlan) {
        self.layout = layout
        self.zoom = zoom
        let canvas = CGRect(origin: .zero, size: layout.canvas)
        background = edit.hasBackground ? Self.backgroundImage(edit.background, in: canvas) : nil
        cornerMask = edit.hasBackground && layout.cornerRadius > 0 ? Self.mask(layout: layout) : nil
    }

    /// The frame for `source` at a time of the source, with its extent the canvas.
    public func image(from source: CIImage, atSource time: TimeInterval) -> CIImage {
        let sourceHeight = source.extent.height
        let kept = layout.crop
        // Core Image counts from the bottom left; the layout from the top left.
        let keptCI = CGRect(x: kept.minX, y: sourceHeight - kept.maxY, width: kept.width, height: kept.height)
        var picture = source.cropped(to: keptCI).transformed(
            by: CGAffineTransform(translationX: -keptCI.minX, y: -keptCI.minY))

        let camera = zoom.camera(at: time)
        if camera.scale > 1.0001 {
            let view = camera.view
            let seen = CGRect(
                x: view.minX * kept.width, y: (1 - view.maxY) * kept.height, width: view.width * kept.width,
                height: view.height * kept.height)
            picture = picture.cropped(to: seen).transformed(
                by: CGAffineTransform(translationX: -seen.minX, y: -seen.minY))
        }
        picture = Self.scaled(picture, to: layout.content.size)
        let origin = CGPoint(x: layout.content.minX, y: layout.canvas.height - layout.content.maxY)
        picture = picture.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))

        let canvas = CGRect(origin: .zero, size: layout.canvas)
        guard let background else { return picture.cropped(to: canvas) }
        if let cornerMask {
            let blend = CIFilter.blendWithMask()
            blend.inputImage = picture
            blend.backgroundImage = background
            blend.maskImage = cornerMask
            return (blend.outputImage ?? picture.composited(over: background)).cropped(to: canvas)
        }
        return picture.composited(over: background).cropped(to: canvas)
    }

    /// Draws a frame into `output`, which is the canvas' size.
    public func render(_ input: CVPixelBuffer, atSource time: TimeInterval, into output: CVPixelBuffer) {
        let frame = image(from: CIImage(cvPixelBuffer: input), atSource: time)
        Self.context.render(
            frame, to: output, bounds: CGRect(origin: .zero, size: layout.canvas),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// A frame as a picture, for a still: the preview where there is no player, and tests.
    public func cgImage(from source: CGImage, atSource time: TimeInterval) -> CGImage? {
        let frame = image(from: CIImage(cgImage: source), atSource: time)
        return Self.context.createCGImage(frame, from: CGRect(origin: .zero, size: layout.canvas))
    }

    // MARK: Pieces

    private static func scaled(_ image: CIImage, to size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let (sx, sy) = (size.width / extent.width, size.height / extent.height)
        if abs(sx - 1) < 1e-6, abs(sy - 1) < 1e-6 {
            return image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        }
        let moved = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        if sx < 1 || sy < 1 {
            // Shrinking: Lanczos keeps text sharp where a plain scale would shimmer.
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = moved
            filter.scale = Float(sy)
            filter.aspectRatio = Float(sx / sy)
            if let output = filter.outputImage { return output.cropped(to: CGRect(origin: .zero, size: size)) }
        }
        return moved.transformed(by: CGAffineTransform(scaleX: sx, y: sy)).cropped(
            to: CGRect(origin: .zero, size: size))
    }

    private static func color(_ hex: UInt32) -> CIColor {
        CIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255)
    }

    private static func backgroundImage(_ fill: BackgroundFill, in canvas: CGRect) -> CIImage? {
        switch fill {
        case .none:
            return nil
        case .solid(let hex):
            return CIImage(color: color(hex)).cropped(to: canvas)
        case .gradient(let from, let to):
            // Drawn with Core Graphics, which blends in the colours' own space as a design tool does; Core Image
            // would blend in linear light, a lighter middle than the board shows.
            let (width, height) = (Int(canvas.width), Int(canvas.height))
            guard
                let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                let gradient = CGGradient(
                    colorsSpace: space, colors: [cgColor(from, space), cgColor(to, space)] as CFArray,
                    locations: [0, 1])
            else { return nil }
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            return context.makeImage().map { CIImage(cgImage: $0) }
        }
    }

    private static func cgColor(_ hex: UInt32, _ space: CGColorSpace) -> CGColor {
        CGColor(
            colorSpace: space,
            components: [
                CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, 1,
            ])!
    }

    /// White where the video shows: its rectangle, rounded. Drawn once.
    private static func mask(layout: FrameLayout) -> CIImage? {
        let (width, height) = (Int(layout.canvas.width), Int(layout.canvas.height))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        // The layout counts from the top, the context from the bottom.
        let rect = CGRect(
            x: layout.content.minX, y: layout.canvas.height - layout.content.maxY, width: layout.content.width,
            height: layout.content.height)
        context.addPath(
            CGPath(
                roundedRect: rect, cornerWidth: layout.cornerRadius, cornerHeight: layout.cornerRadius, transform: nil))
        context.fillPath()
        return context.makeImage().map { CIImage(cgImage: $0) }
    }
}

// MARK: AVFoundation

/// One instruction for the whole video: which track to draw from and how.
final class EditInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let trackID: CMPersistentTrackID
    let renderer: FrameRenderer
    /// Turns the composition's time into the source's: the export. Nil where the two are the same, as in the preview.
    let map: TimelineMap?

    var enablePostProcessing: Bool { false }
    var containsTweening: Bool { true }
    var requiredSourceTrackIDs: [NSValue]? { [NSNumber(value: trackID)] }
    var passthroughTrackID: CMPersistentTrackID { kCMPersistentTrackID_Invalid }

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, renderer: FrameRenderer, map: TimelineMap?) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.renderer = renderer
        self.map = map
    }
}

/// Hands each frame to its instruction's renderer.
final class EditCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "net.icuai.topdeck.editor.compositor", qos: .userInitiated)
    private let lock = NSLock()
    private var context: AVVideoCompositionRenderContext?

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        lock.withLock { context = newRenderContext }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            guard let instruction = request.videoCompositionInstruction as? EditInstruction,
                let source = request.sourceFrame(byTrackID: instruction.trackID),
                let output = lock.withLock({ context })?.newPixelBuffer()
            else {
                request.finish(with: CocoaError(.fileReadUnknown))
                return
            }
            let time = request.compositionTime.seconds
            let sourceTime = instruction.map?.toSource(time) ?? time
            instruction.renderer.render(source, atSource: sourceTime, into: output)
            request.finish(withComposedVideoFrame: output)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

/// Builds the AVFoundation objects for an edit: the trimmed and re-timed composition and its video composition,
/// for the export, and the video composition alone for the preview of the untouched source.
enum EditComposition {
    struct Prepared {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let videoTrack: AVAssetTrack
        let audioTracks: [AVAssetTrack]
        let audioMix: AVAudioMix?
    }

    enum Failure: Error { case noVideo, cannotBuild }

    static func build(asset: AVAsset, plan: ExportPlan, renderer: FrameRenderer) async throws -> Prepared {
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let trim = plan.map.trim
        let range = CMTimeRange(
            start: CMTime(seconds: trim.lowerBound, preferredTimescale: 600),
            end: CMTime(seconds: trim.upperBound, preferredTimescale: 600))
        let composition = AVMutableComposition()
        guard
            let video = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw Failure.cannotBuild }
        try video.insertTimeRange(range, of: sourceVideo, at: .zero)

        // Each kept audio track on a track of its own, with its gain.
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio)
        var audio: [AVMutableCompositionTrack] = []
        var parameters: [AVMutableAudioMixInputParameters] = []
        for (index, gain) in plan.audio where index < sourceAudio.count {
            guard
                let track = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try track.insertTimeRange(range, of: sourceAudio[index], at: .zero)
            audio.append(track)
            let mix = AVMutableAudioMixInputParameters(track: track)
            mix.setVolume(gain, at: .zero)
            parameters.append(mix)
        }

        // Speed: each span stretched or squeezed, last first so the earlier ones stay where they were.
        for span in plan.map.spans.reversed() where span.rate != 1 {
            let start = CMTime(seconds: span.sourceStart - trim.lowerBound, preferredTimescale: 600)
            let length = CMTime(seconds: span.sourceEnd - span.sourceStart, preferredTimescale: 600)
            let scaled = CMTime(seconds: (span.sourceEnd - span.sourceStart) / span.rate, preferredTimescale: 600)
            composition.scaleTimeRange(CMTimeRange(start: start, duration: length), toDuration: scaled)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = EditCompositor.self
        videoComposition.renderSize = plan.layout.canvas
        videoComposition.frameDuration = CMTime(seconds: 1 / plan.framesPerSecond, preferredTimescale: 6000)
        videoComposition.instructions = [
            EditInstruction(
                timeRange: CMTimeRange(start: .zero, duration: composition.duration), trackID: video.trackID,
                renderer: renderer, map: plan.map)
        ]
        var mix: AVAudioMix?
        if plan.audio.contains(where: { $0.gain != 1 }) {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = parameters
            mix = audioMix
        }
        return Prepared(
            composition: composition, videoComposition: videoComposition, videoTrack: video, audioTracks: audio,
            audioMix: mix)
    }

    /// The video composition for playing `asset` itself (composition time is source time).
    static func preview(asset: AVAsset, renderer: FrameRenderer, framesPerSecond: Double) async -> AVVideoComposition? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
            let duration = try? await asset.load(.duration)
        else { return nil }
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = EditCompositor.self
        composition.renderSize = renderer.layout.canvas
        composition.frameDuration = CMTime(seconds: 1 / min(max(framesPerSecond, 15), 60), preferredTimescale: 6000)
        composition.instructions = [
            EditInstruction(
                timeRange: CMTimeRange(start: .zero, duration: duration), trackID: track.trackID, renderer: renderer,
                map: nil)
        ]
        return composition
    }
}
