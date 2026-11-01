// SPDX-License-Identifier: MIT
import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import Testing

@testable import TopdeckFeatures

/// A short test video made in code: left half red, right half blue, brighter as it goes, optionally with a
/// tone. It stands in for a recording.
enum SyntheticVideo {
    /// Feeds one writer input from its own queue until it has had `count` items.
    private final class Feeder: @unchecked Sendable {
        private let input: AVAssetWriterInput
        private let count: Int
        private let item: (Int) -> Bool
        private var next = 0
        private var finished = false

        init(_ input: AVAssetWriterInput, count: Int, item: @escaping (Int) -> Bool) {
            self.input = input
            self.count = count
            self.item = item
        }

        func start(on queue: DispatchQueue, group: DispatchGroup) {
            group.enter()
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while input.isReadyForMoreMediaData, !finished {
                    if next >= count || !item(next) {
                        finished = true
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    next += 1
                }
            }
        }
    }

    /// `picture` is drawn in each frame in place of the red and blue halves.
    static func make(
        at url: URL, seconds: Double, fps: Int = 30, width: Int = 320, height: Int = 180, audio: Bool = false,
        audioTracks: Int = 1, picture still: CGImage? = nil
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(video)
        var sound: AVAssetWriterInput?
        var extra: AVAssetWriterInput?
        if audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: RecordingEncoding.audioSettings())
            writer.add(input)
            sound = input
            if audioTracks > 1 {
                let more = AVAssetWriterInput(mediaType: .audio, outputSettings: RecordingEncoding.audioSettings())
                writer.add(more)
                extra = more
            }
        }
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frames = Int((seconds * Double(fps)).rounded())
        let samplesPerFrame = 48_000 / fps
        let group = DispatchGroup()
        let picture = Feeder(video, count: frames) { index in
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let pixels = buffer else { return false }
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            let glow = UInt8(min(255, 60 + index * 195 / max(frames, 1)))
            if let still {
                if let context = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                {
                    context.draw(still, in: CGRect(x: 0, y: 0, width: width, height: height))
                }
                CVPixelBufferUnlockBaseAddress(pixels, [])
                return adaptor.append(
                    pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
            }
            for y in 0..<height {
                for x in 0..<width {
                    let at = y * stride + x * 4  // B, G, R, A
                    base[at] = x < width / 2 ? 0 : glow
                    base[at + 1] = 0
                    base[at + 2] = x < width / 2 ? glow : 0
                    base[at + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            return adaptor.append(
                pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
        }
        picture.start(on: DispatchQueue(label: "synthetic.video"), group: group)
        var tone: Feeder?
        if let sound {
            tone = Feeder(sound, count: frames) { index in
                guard let sample = try? Self.tone(from: index * samplesPerFrame, count: samplesPerFrame) else {
                    return false
                }
                return sound.append(sample)
            }
            tone?.start(on: DispatchQueue(label: "synthetic.audio"), group: group)
        }
        var more: Feeder?
        if let extra {
            more = Feeder(extra, count: frames) { index in
                guard let sample = try? Self.tone(from: index * samplesPerFrame, count: samplesPerFrame) else {
                    return false
                }
                return extra.append(sample)
            }
            more?.start(on: DispatchQueue(label: "synthetic.audio2"), group: group)
        }
        await withCheckedContinuation { continuation in group.notify(queue: .global()) { continuation.resume() } }
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
        withExtendedLifetime((picture, tone, more)) {}
    }

    private static func check(_ writer: AVAssetWriter) throws {
        if writer.status == .failed || writer.status == .cancelled {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    /// A 440 Hz tone, stereo float PCM, `count` samples from `start`.
    private static func tone(from start: Int, count: Int) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format)
        var samples = [Float](repeating: 0, count: count * 2)
        for index in 0..<count {
            let value = Float(0.3 * sin(2 * Double.pi * 440 * Double(start + index) / 48_000))
            samples[index * 2] = value
            samples[index * 2 + 1] = value
        }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: samples.count * 4, blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0, dataLength: samples.count * 4, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        CMBlockBufferReplaceDataBytes(
            with: samples, blockBuffer: try #require(block), offsetIntoDestination: 0, dataLength: samples.count * 4)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: try #require(format), sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: 48_000), packetDescriptions: nil,
            sampleBufferOut: &sample)
        return try #require(sample)
    }
}

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "Export-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Safe to read from the export's thread: it only ever appends.
private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.withLock { values.append(value) } }
    var all: [Double] { lock.withLock { values } }
}

struct VideoExportTests {
    @Test func theSourceFramesComeOutAsBigAsTheyWentIn() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "clip.mp4")
        try await SyntheticVideo.make(at: source, seconds: 2)
        let asset = AVURLAsset(url: source)
        #expect(abs(try await asset.load(.duration).seconds - 2) < 0.1)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 320, height: 180))
    }

    @Test func exportRunsTheEditThroughTrimSpeedAndZoom() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "clip.mp4")
        try await SyntheticVideo.make(at: source, seconds: 4)
        let before = try Data(contentsOf: source)

        var edit = VideoEdit()
        edit.trimStart = 0.5
        edit.trimEnd = 3.5  // three seconds…
        edit.speeds = [SpeedSegment(start: 1, duration: 1, rate: 2)]  // …of which one plays in half a second
        edit.zooms = [ZoomSegment(start: 1.5, duration: 1, scale: 2, follows: false, target: CGPoint(x: 0.75, y: 0.5))]
        let destination = folder.appending(path: "clip edited.mp4")
        let progress = Progress()
        try await VideoExporter.export(source: source, edit: edit, cursor: nil, to: destination) { progress.add($0) }

        let asset = AVURLAsset(url: destination)
        let seconds = try await asset.load(.duration).seconds
        #expect(abs(seconds - 2.5) < 0.15, "three seconds less half of one that went twice as fast: \(seconds)")
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 320, height: 180))
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(abs(Double(try await track.load(.nominalFrameRate)) - 30) < 2)
        #expect(try Data(contentsOf: source) == before, "the source is untouched")
        #expect(!FileManager.default.fileExists(atPath: destination.path + ".partial"), "nothing left behind")
        let reported = progress.all
        #expect(reported.last == 1 && reported == reported.sorted() && reported.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(reported.count > 2, "it reports as it goes")
    }

    @Test func aCroppedFramedSmallerExportHasTheLayoutsSize() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "clip.mp4")
        try await SyntheticVideo.make(at: source, seconds: 1)
        var edit = VideoEdit()
        edit.crop = CropRegion(x: 0, y: 0, width: 0.5, height: 1)  // 160 by 180
        edit.background = .gradient(from: 0x2B4C7E, to: 0xC86A7A)
        let layout = FrameLayout(source: CGSize(width: 320, height: 180), edit: edit)
        #expect(layout.canvas == CGSize(width: 176, height: 196), "7.68 pixels of padding a side, made even")
        let destination = folder.appending(path: "framed.mp4")
        try await VideoExporter.export(source: source, edit: edit, cursor: nil, to: destination) { _ in }
        let track = try #require(try await AVURLAsset(url: destination).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == layout.canvas)

        edit.export.size = .p480
        edit.padding = 200  // a wide margin: the canvas is now 224 by 244, still under the box
        let again = folder.appending(path: "framed 2.mp4")
        try await VideoExporter.export(source: source, edit: edit, cursor: nil, to: again) { _ in }
        let second = try #require(try await AVURLAsset(url: again).loadTracks(withMediaType: .video).first)
        #expect(
            try await second.load(.naturalSize)
                == FrameLayout(source: CGSize(width: 320, height: 180), edit: edit, box: ExportSize.p480.box).canvas)
    }

    @Test func aBigPictureIsShrunkToThePresetAndNeverEnlarged() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "big.mp4")
        try await SyntheticVideo.make(at: source, seconds: 0.5, width: 1280, height: 720)
        var edit = VideoEdit()
        edit.export.size = .p480
        let destination = folder.appending(path: "big 480.mp4")
        try await VideoExporter.export(source: source, edit: edit, cursor: nil, to: destination) { _ in }
        let track = try #require(try await AVURLAsset(url: destination).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 854, height: 480))
        edit.export.size = .p1080
        let same = folder.appending(path: "big 1080.mp4")
        try await VideoExporter.export(source: source, edit: edit, cursor: nil, to: same) { _ in }
        let unchanged = try #require(try await AVURLAsset(url: same).loadTracks(withMediaType: .video).first)
        #expect(try await unchanged.load(.naturalSize) == CGSize(width: 1280, height: 720))
    }

    @Test func aGIFHasEveryFrameAtItsSize() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "clip.mp4")
        try await SyntheticVideo.make(at: source, seconds: 2, width: 160, height: 90)
        var edit = VideoEdit()
        edit.export.format = .gif
        edit.export.size = .p720
        edit.export.quality = .low
        edit.trimEnd = 1.5
        let plan = ExportPlan(
            source: CGSize(width: 160, height: 90), duration: 2, sourceFramesPerSecond: 30, audioTracks: 0, edit: edit)
        let destination = folder.appending(path: "clip.gif")
        try await VideoExporter.export(source: source, edit: edit, cursor: nil, to: destination) { _ in }
        let image = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        #expect(
            CGImageSourceGetCount(image) == plan.frameCount && plan.frameCount == 12,
            "eight a second for a second and a half")
        let first = try #require(CGImageSourceCreateImageAtIndex(image, 0, nil))
        #expect(first.width == 160 && first.height == 90, "never enlarged")
        #expect(CGImageSourceGetType(image) as String? == "com.compuserve.gif")
    }

    @Test func mutingAndKeepingTracksDecidesWhatSoundIsWritten() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "voice.mp4")
        try await SyntheticVideo.make(at: source, seconds: 1.5, audio: true)
        let kept = folder.appending(path: "kept.mp4")
        var edit = VideoEdit()
        edit.trimStart = 0.5
        edit.setAudio(AudioTrackSetting(volume: 0.5), at: 0)
        try await VideoExporter.export(source: source, edit: edit, cursor: nil, to: kept) { _ in }
        let keptAsset = AVURLAsset(url: kept)
        #expect(try await keptAsset.loadTracks(withMediaType: .audio).count == 1)
        #expect(abs(try await keptAsset.load(.duration).seconds - 1) < 0.15)
        edit.setAudio(AudioTrackSetting(volume: 0.5, muted: true), at: 0)
        let muted = folder.appending(path: "muted.mp4")
        try await VideoExporter.export(source: source, edit: edit, cursor: nil, to: muted) { _ in }
        #expect(try await AVURLAsset(url: muted).loadTracks(withMediaType: .audio).isEmpty)
        #expect(try await AVURLAsset(url: muted).loadTracks(withMediaType: .video).count == 1)
    }

    @Test func cancellingStopsTheExportAndLeavesNothing() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "long.mp4")
        try await SyntheticVideo.make(at: source, seconds: 6, width: 640, height: 360)
        let destination = folder.appending(path: "long edited.mp4")
        final class Holder: @unchecked Sendable {
            var task: Task<Void, Error>?
        }
        let holder = Holder()
        holder.task = Task {
            try await VideoExporter.export(source: source, edit: VideoEdit(), cursor: nil, to: destination) { value in
                if value > 0.15 { holder.task?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await holder.task?.value }
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left == ["long.mp4"], "no export, no partial file: \(left)")
    }

    @Test func itWillNotWriteOverTheSource() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "clip.mp4")
        try await SyntheticVideo.make(at: source, seconds: 0.5)
        let before = try Data(contentsOf: source)
        await #expect(throws: VideoExportError.self) {
            try await VideoExporter.export(source: source, edit: VideoEdit(), cursor: nil, to: source) { _ in }
        }
        #expect(try Data(contentsOf: source) == before)
    }

    @Test func exportingKeepsAnExistingPartialAndReplacesTheChosenOutput() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "clip.mp4")
        try await SyntheticVideo.make(at: source, seconds: 0.5)
        let destination = folder.appending(path: "edited.mp4")
        let partial = URL(filePath: destination.path + ".partial")
        let existing = Data("keep this file".utf8)
        try existing.write(to: partial)
        try Data("old export".utf8).write(to: destination)
        try await VideoExporter.export(source: source, edit: VideoEdit(), cursor: nil, to: destination) { _ in }
        #expect(try Data(contentsOf: partial) == existing)
        #expect(try await AVURLAsset(url: destination).loadTracks(withMediaType: .video).count == 1)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
                == ["clip.mp4", "edited.mp4", "edited.mp4.partial"])
    }

    @Test func aSourceSymlinkCannotBeUsedAsTheExportDestination() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "clip.mp4")
        try await SyntheticVideo.make(at: source, seconds: 0.5)
        let before = try Data(contentsOf: source)
        let alias = folder.appending(path: "alias.mp4")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        await #expect(throws: VideoExportError.self) {
            try await VideoExporter.export(source: source, edit: VideoEdit(), cursor: nil, to: alias) { _ in }
        }
        #expect(try Data(contentsOf: source) == before)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == source.path)
    }

    @Test func aFileWithNoPictureIsRefused() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let notVideo = folder.appending(path: "note.mp4")
        try Data("nothing to see".utf8).write(to: notVideo)
        await #expect(throws: (any Error).self) {
            try await VideoExporter.export(
                source: notVideo, edit: VideoEdit(), cursor: nil, to: folder.appending(path: "out.mp4")
            ) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["note.mp4"])
    }
}

@MainActor
struct EditorModelTests {
    private func model(seconds: Double = 4, audio: Bool = false) async throws -> (EditorModel, URL) {
        let folder = try temporaryFolder()
        let url = folder.appending(path: "Screen Recording 2026-10-30 at 14.03.22.mp4")
        try await SyntheticVideo.make(at: url, seconds: seconds, audio: audio)
        let model = EditorModel(url: url, saveDelay: .milliseconds(20))
        await model.load()
        return (model, url)
    }

    @Test func aVideoOpensWithItsLengthSizeAndNothingChanged() async throws {
        let (model, url) = try await model(audio: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(model.phase == .ready && abs(model.duration - 4) < 0.1)
        #expect(model.sourceSize == CGSize(width: 320, height: 180) && model.audioLabels == ["Audio"])
        #expect(model.edit.isUnchanged && model.trim.upperBound == model.duration && !model.canUndo)
        #expect(model.previewLayout == nil || model.previewLayout?.canvas == CGSize(width: 320, height: 180))
        #expect(await eventually { model.thumbnails.count == 16 && model.thumbnails.allSatisfy { $0 != nil } })
    }

    @Test func aFileThatIsNotAVideoFailsToOpenWithAMessage() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "x.mp4")
        try Data("no".utf8).write(to: url)
        let model = EditorModel(url: url)
        await model.load()
        guard case .failed = model.phase else {
            Issue.record("expected a failure, got \(model.phase)")
            return
        }
    }

    @Test func undoAndRedoStepThroughChangesAndADragIsOneStep() async throws {
        let (model, url) = try await model()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        model.setTrim(.start, to: 1)
        model.setTrim(.start, to: 1.2)
        model.setTrim(.start, to: 1.4)  // one drag
        #expect(model.edit.trimStart == 1.4 && model.canUndo)
        model.apply { $0.corners = 30 }
        model.apply { $0.padding = 80 }
        model.undo()
        #expect(model.edit.padding == 48 && model.edit.corners == 30)
        model.undo()
        #expect(model.edit.corners == 12 && model.edit.trimStart == 1.4)
        model.undo()
        #expect(model.edit.trimStart == 0 && !model.canUndo && model.canRedo, "the whole drag in one step")
        model.redo()
        model.redo()
        #expect(model.edit.trimStart == 1.4 && model.edit.corners == 30)
        model.undo()
        model.apply { $0.corners = 5 }
        #expect(!model.canRedo, "a new change drops what was undone")
    }

    @Test func aStepAfterADragIsItsOwnStepAndNothingToChangeIsNoStep() async throws {
        let (model, url) = try await model()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        model.apply("padding") { $0.padding = 60 }
        model.apply("padding") { $0.padding = 70 }
        model.apply("corners") { $0.corners = 20 }
        model.apply("corners") { $0.corners = 20 }
        model.undo()
        #expect(model.edit.corners == 12 && model.edit.padding == 70)
        model.undo()
        #expect(model.edit.padding == 48 && !model.canUndo)
    }

    @Test func theEditIsKeptBesideTheVideoAndComesBackOnReopening() async throws {
        let (model, url) = try await model(audio: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        model.seek(to: 1)
        #expect(model.addZoom() && model.selectedZoom?.start == 1)
        model.setTrim(.end, to: 3)
        model.apply { $0.background = BackgroundFill.presets[0] }
        model.apply { $0.setAudio(AudioTrackSetting(volume: 0.4), at: 0) }
        model.flush()
        #expect(FileManager.default.fileExists(atPath: EditSidecar.url(for: url).path))
        let reopened = EditorModel(url: url)
        await reopened.load()
        #expect(reopened.edit == model.edit && reopened.edit.zooms.count == 1)
        #expect(reopened.trim.upperBound == 3)
        model.undo()
        model.undo()
        model.undo()
        model.undo()
        model.flush()
        #expect(!FileManager.default.fileExists(atPath: EditSidecar.url(for: url).path), "no edit, no file")
    }

    @Test func segmentsAreAddedAtThePlayheadMovedStretchedAndDeleted() async throws {
        let (model, url) = try await model()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        model.seek(to: 1)
        #expect(model.addZoom())
        guard case .zoom(let first) = model.selection else {
            Issue.record("not picked")
            return
        }
        model.seek(to: 2)
        #expect(!model.addZoom(), "inside the first")
        model.seek(to: 3.2)
        #expect(model.addZoom())
        guard case .zoom(let second) = model.selection else {
            Issue.record("not picked")
            return
        }
        func zoom(_ id: UUID) -> ZoomSegment? { model.edit.zooms.first { $0.id == id } }
        #expect(zoom(second)?.start == 3.2 && zoom(second)?.end == 4, "it ends with the video")
        model.moveSegment(.zoom(second), to: 0)  // stops against the first, which ends at 3
        #expect(zoom(second)?.start == 3 && abs((zoom(second)?.duration ?? 0) - 0.8) < 1e-9)
        model.moveSegment(.zoom(first), to: 0.2)
        #expect(zoom(first)?.start == 0.2 && zoom(first)?.end == 2.2, "free to move until it meets the next")
        model.moveSegment(.zoom(first), to: 9)
        #expect(zoom(first)?.end == 3, "and stops there")
        model.resizeSegment(.zoom(first), edge: .start, to: 2.9)
        #expect(zoom(first)?.start == 2.5, "no shorter than half a second")
        model.resizeSegment(.zoom(second), edge: .end, to: 99)
        #expect(zoom(second)?.end == 4, "no longer than the video")
        model.selection = .zoom(first)
        model.deleteSelection()
        #expect(model.edit.zooms.map(\.id) == [second] && model.selection == nil)
        model.undo()
        #expect(model.edit.zooms.count == 2)
        model.seek(to: 0)
        #expect(model.addSpeed() && model.edit.speeds.count == 1 && model.selectedSpeed?.start == 0)
    }

    @Test func aGIFNeverStartsAtTheOriginalSize() async throws {
        let (model, url) = try await model()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        model.setFormat(.gif)
        #expect(model.edit.export.format == .gif && model.edit.export.size == .p720)
        model.apply { $0.export.size = .p1080 }
        model.setFormat(.mp4)
        #expect(model.edit.export.size == .p1080, "a size that was picked stays")
    }

    @Test func exportingMakesANewFileBesideTheSourceAndTellsWhoAsked() async throws {
        let (model, url) = try await model(seconds: 1.5)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var exported: URL?
        model.onExported = { exported = $0 }
        model.apply { $0.trimStart = 0.5 }
        model.export()
        #expect(model.isExporting)
        #expect(await eventually { exported != nil })
        let file = try #require(exported)
        #expect(file.deletingLastPathComponent().path == url.deletingLastPathComponent().path)
        #expect(file.lastPathComponent == "Screen Recording 2026-10-30 at 14.03.22 edited.mp4")
        #expect(model.exportState == .done(file))
        #expect(abs(try await AVURLAsset(url: file).load(.duration).seconds - 1) < 0.15)
        model.dismissExport()
        #expect(model.exportState == .idle)
        model.export()  // the name is taken: the next one is numbered
        #expect(await eventually { model.exportState != .idle && !model.isExporting })
        #expect(
            model.exportState
                == .done(
                    file.deletingLastPathComponent().appending(
                        path: "Screen Recording 2026-10-30 at 14.03.22 edited 2.mp4")))
    }

    @Test func cancellingAnExportInTheModelBringsItBackToIdle() async throws {
        let (model, url) = try await model(seconds: 6)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        model.export()
        model.cancelExport()
        #expect(model.exportState == .idle)
        try await Task.sleep(for: .milliseconds(600))
        #expect(model.exportState == .idle || !model.isExporting)
        model.close()
    }

    @Test func aCancelledExportCannotClearItsReplacement() async throws {
        let (model, url) = try await model(seconds: 1.5)
        defer {
            model.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let destination = url.deletingLastPathComponent().appending(path: "replacement.mp4")
        model.export(to: destination)
        model.cancelExport()
        model.export(to: destination)
        #expect(await eventually { !model.isExporting })
        #expect(model.exportState == .done(destination))
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }
}
