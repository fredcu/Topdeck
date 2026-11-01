// SPDX-License-Identifier: MIT
@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Observation
import TopdeckCore

/// One video open in the editor: the file, the edit made to it, the player, and the export. The edit is a value
/// (`VideoEdit`), so undo and redo are copies of it; it is written beside the video a moment after each change.
@MainActor
@Observable
public final class EditorModel {
    public enum Tool: String, CaseIterable, Identifiable, Sendable {
        case trim, zoom, crop, speed, background, audio

        public var id: Self { self }
        public var title: String { rawValue.capitalized }
    }

    public enum Selection: Equatable, Sendable {
        case zoom(UUID)
        case speed(UUID)
    }

    public enum Phase: Equatable, Sendable {
        case loading
        case ready
        case failed(String)
    }

    public enum ExportState: Equatable, Sendable {
        case idle
        case running(Double)
        case done(URL)
        case failed(String)
    }

    public let url: URL
    public private(set) var phase = Phase.loading
    public private(set) var edit = VideoEdit()
    public private(set) var duration: TimeInterval = 0
    public private(set) var sourceSize = CGSize.zero
    public private(set) var frameRate = 30.0
    /// A name for each audio track of the file, in order.
    public private(set) var audioLabels: [String] = []
    public private(set) var cursor: CursorTrack?
    /// The strip's frames, in order; nil until each is made.
    public private(set) var thumbnails: [CGImage?] = []
    /// Where the playhead is, in seconds of the source.
    public private(set) var playhead: TimeInterval = 0
    public private(set) var isPlaying = false
    public private(set) var exportState = ExportState.idle
    /// The layout of what the preview shows.
    public private(set) var previewLayout: FrameLayout?
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    public var tool = Tool.trim {
        // Cropping is done on the whole picture, so the preview shows it whole while that tool is out.
        didSet { if (oldValue == .crop) != (tool == .crop) { rebuildPreview() } }
    }
    public var selection: Selection?
    /// The first picture of the video as the edit draws it, under the player: what shows before the player has a
    /// frame, and where no player can draw.
    public private(set) var previewStill: CGImage?

    @ObservationIgnored public let player = AVPlayer()
    /// Called with the file an export made.
    @ObservationIgnored public var onExported: ((URL) -> Void)?
    /// The first picture of the source, for a still preview where a player can't draw.
    @ObservationIgnored public private(set) var stillFrame: CGImage? {
        didSet { if stillFrame != nil, oldValue == nil { rebuildPreview() } }
    }

    /// The most the preview draws, in pixels: enough for the window, light enough to scrub.
    static let previewBox = CGSize(width: 1280, height: 800)
    private static let thumbnailCount = 16

    @ObservationIgnored private var asset: AVURLAsset?
    @ObservationIgnored private var audioTracks: [AVAssetTrack] = []
    @ObservationIgnored private var undoStack: [VideoEdit] = []
    @ObservationIgnored private var redoStack: [VideoEdit] = []
    @ObservationIgnored private var lastChange: (key: String, at: Date)?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var exportID: UUID?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let saveDelay: Duration

    public init(url: URL, now: @escaping () -> Date = { .now }, saveDelay: Duration = .milliseconds(400)) {
        self.url = url
        self.now = now
        self.saveDelay = saveDelay
    }

    // MARK: Derived

    public var trim: ClosedRange<TimeInterval> { edit.trim(duration: duration) }
    public var map: TimelineMap { TimelineMap(trim: trim, speeds: edit.speeds) }
    public var zoomPlan: ZoomPlan { ZoomPlan(segments: edit.zooms, cursor: cursor) }
    public var canFollowCursor: Bool { cursor?.isUsable == true }
    public var isExporting: Bool {
        if case .running = exportState { true } else { false }
    }

    public var selectedZoom: ZoomSegment? {
        guard case .zoom(let id) = selection else { return nil }
        return edit.zooms.first { $0.id == id }
    }

    public var selectedSpeed: SpeedSegment? {
        guard case .speed(let id) = selection else { return nil }
        return edit.speeds.first { $0.id == id }
    }

    /// The length of what is exported, with the speed segments played at their rates.
    public var outputDuration: TimeInterval { map.outputDuration }

    // MARK: Loading

    /// Reads the video's properties, the saved edit and the recorded pointer, and makes the preview and the strip.
    public func load() async {
        guard phase == .loading else { return }
        let asset = AVURLAsset(url: url)
        do {
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                phase = .failed("This file has no video")
                return
            }
            let length = try await asset.load(.duration).seconds
            guard length.isFinite, length > 0 else {
                phase = .failed("This video is empty")
                return
            }
            sourceSize = try await video.load(.naturalSize)
            let rate = Double(try await video.load(.nominalFrameRate))
            frameRate = rate > 0 ? rate : 30
            let audio = try await asset.loadTracks(withMediaType: .audio)
            audioTracks = audio
            duration = length
        } catch {
            phase = .failed("Couldn't open this video")
            return
        }
        self.asset = asset
        cursor = CursorTrack.load(for: url)
        audioLabels = Self.labels(count: audioTracks.count, roles: cursor?.audio ?? [])
        if let saved = EditSidecar.load(for: url, duration: duration) { edit = saved }
        playhead = trim.lowerBound
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        phase = .ready
        seek(to: playhead)
        rebuildPreview()
        updateAudioMix()
        loadThumbnails(asset)
    }

    /// "System audio" and "Microphone" for what Topdeck recorded; "Audio" for anything else.
    static func labels(count: Int, roles: [String]) -> [String] {
        (0..<count).map { index in
            guard index < roles.count else { return count == 1 ? "Audio" : "Audio \(index + 1)" }
            return roles[index] == "microphone" ? "Microphone" : "System audio"
        }
    }

    private func loadThumbnails(_ asset: AVURLAsset) {
        let times = TimelineScale(duration: duration, width: 1).frameTimes(count: Self.thumbnailCount)
        thumbnails = Array(repeating: nil, count: times.count)
        Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 360)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            let cmTimes = times.map { CMTime(seconds: $0, preferredTimescale: 600) }
            for await result in generator.images(for: cmTimes) {
                guard let self, case .success(let requested, let image, _) = result,
                    let index = cmTimes.firstIndex(of: requested)
                else { continue }
                if index < thumbnails.count { thumbnails[index] = image }
                if stillFrame == nil, index == 0 { stillFrame = image }
            }
        }
    }

    // MARK: Editing

    /// Applies a change to the edit. Changes with the same `key` a moment apart (a slider being dragged) are one
    /// step of undo.
    public func apply(_ key: String? = nil, _ change: (inout VideoEdit) -> Void) {
        var changed = edit
        change(&changed)
        guard changed != edit else { return }
        let time = now()
        if let key, let last = lastChange, last.key == key, time.timeIntervalSince(last.at) < 1 {
            // part of the same drag
        } else {
            undoStack.append(edit)
            if undoStack.count > 100 { undoStack.removeFirst() }
        }
        lastChange = key.map { ($0, time) }
        redoStack.removeAll()
        commit(changed)
    }

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(edit)
        lastChange = nil
        commit(previous)
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(edit)
        lastChange = nil
        commit(next)
    }

    private func commit(_ new: VideoEdit) {
        edit = new
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        if let selection {
            switch selection {
            case .zoom(let id): if !edit.zooms.contains(where: { $0.id == id }) { self.selection = nil }
            case .speed(let id): if !edit.speeds.contains(where: { $0.id == id }) { self.selection = nil }
            }
        }
        if playhead < trim.lowerBound || playhead > trim.upperBound, isPlaying { pause() }
        rebuildPreview()
        updateAudioMix()
        scheduleSave()
    }

    /// Moves a trim handle. The trim keeps at least half a second.
    public func setTrim(_ edge: SegmentDrag.Edge, to time: TimeInterval) {
        let moved = SegmentDrag.trimmed(trim, edge: edge, to: time, duration: duration, least: VideoEdit.minimumLength)
        apply("trim") {
            $0.trimStart = moved.lowerBound
            $0.trimEnd = moved.upperBound >= duration - 0.001 ? nil : moved.upperBound
        }
    }

    /// Adds a zoom at the playhead and picks it. False when there is no room.
    @discardableResult
    public func addZoom() -> Bool {
        var added: UUID?
        let follows = canFollowCursor
        apply { added = $0.addZoom(at: playhead, duration: duration, follows: follows) }
        guard let added else { return false }
        selection = .zoom(added)
        return true
    }

    @discardableResult
    public func addSpeed() -> Bool {
        var added: UUID?
        apply { added = $0.addSpeed(at: playhead, duration: duration) }
        guard let added else { return false }
        selection = .speed(added)
        return true
    }

    public func updateZoom(_ id: UUID, key: String? = nil, _ change: (inout ZoomSegment) -> Void) {
        apply(key ?? "zoom-\(id)") { edit in
            guard let index = edit.zooms.firstIndex(where: { $0.id == id }) else { return }
            var zoom = edit.zooms[index]
            change(&zoom)
            edit.zooms[index] = ZoomSegment(
                id: id, start: zoom.start, duration: zoom.duration, scale: zoom.scale, follows: zoom.follows,
                target: zoom.target)
        }
    }

    public func updateSpeed(_ id: UUID, key: String? = nil, _ change: (inout SpeedSegment) -> Void) {
        apply(key ?? "speed-\(id)") { edit in
            guard let index = edit.speeds.firstIndex(where: { $0.id == id }) else { return }
            var speed = edit.speeds[index]
            change(&speed)
            edit.speeds[index] = SpeedSegment(id: id, start: speed.start, duration: speed.duration, rate: speed.rate)
        }
    }

    /// Drags a segment's body to start at `time`, stopping at its neighbours and the trim.
    public func moveSegment(_ selection: Selection, to time: TimeInterval) {
        switch selection {
        case .zoom(let id):
            guard let zoom = edit.zooms.first(where: { $0.id == id }) else { return }
            let others = edit.zooms.filter { $0.id != id }.map { $0.start...$0.end }
            let start = SegmentDrag.moved(current: zoom.start...zoom.end, to: time, among: others, within: trim)
            updateZoom(id, key: "drag-\(id)") { $0.start = start }
        case .speed(let id):
            guard let speed = edit.speeds.first(where: { $0.id == id }) else { return }
            let others = edit.speeds.filter { $0.id != id }.map { $0.start...$0.end }
            let start = SegmentDrag.moved(current: speed.start...speed.end, to: time, among: others, within: trim)
            updateSpeed(id, key: "drag-\(id)") { $0.start = start }
        }
    }

    /// Drags one end of a segment to `time`.
    public func resizeSegment(_ selection: Selection, edge: SegmentDrag.Edge, to time: TimeInterval) {
        switch selection {
        case .zoom(let id):
            guard let zoom = edit.zooms.first(where: { $0.id == id }) else { return }
            let others = edit.zooms.filter { $0.id != id }.map { $0.start...$0.end }
            let range = SegmentDrag.resized(
                current: zoom.start...zoom.end, edge: edge, to: time, among: others, within: trim,
                least: ZoomSegment.minimumDuration, most: ZoomSegment.maximumDuration)
            updateZoom(id, key: "drag-\(id)") {
                $0.start = range.lowerBound
                $0.duration = range.upperBound - range.lowerBound
            }
        case .speed(let id):
            guard let speed = edit.speeds.first(where: { $0.id == id }) else { return }
            let others = edit.speeds.filter { $0.id != id }.map { $0.start...$0.end }
            let range = SegmentDrag.resized(
                current: speed.start...speed.end, edge: edge, to: time, among: others, within: trim,
                least: SpeedSegment.minimumDuration)
            updateSpeed(id, key: "drag-\(id)") {
                $0.start = range.lowerBound
                $0.duration = range.upperBound - range.lowerBound
            }
        }
    }

    /// Removes the picked zoom or speed segment.
    public func deleteSelection() {
        guard let selection else { return }
        apply {
            switch selection {
            case .zoom(let id): $0.zooms.removeAll { $0.id == id }
            case .speed(let id): $0.speeds.removeAll { $0.id == id }
            }
        }
        self.selection = nil
    }

    public func setFormat(_ format: ExportFormat) {
        apply {
            $0.export.format = format
            // A GIF the size of the screen is hundreds of megabytes.
            if format == .gif, $0.export.size == .original { $0.export.size = .p720 }
        }
    }

    // MARK: Playback

    public func togglePlay() { isPlaying ? pause() : play() }

    public func play() {
        guard phase == .ready else { return }
        let range = trim
        if playhead < range.lowerBound || playhead >= range.upperBound - 0.05 { seek(to: range.lowerBound) }
        isPlaying = true
        player.rate = Float(map.rate(atSource: playhead))
    }

    public func pause() {
        isPlaying = false
        player.pause()
    }

    /// Puts the playhead at `time`, held to the video.
    public func seek(to time: TimeInterval) {
        let target = min(max(time, 0), duration)
        playhead = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func tick(_ time: TimeInterval) {
        guard isPlaying else { return }
        let range = trim
        if time >= range.upperBound - 0.02 {
            pause()
            seek(to: range.upperBound)
            return
        }
        playhead = time
        let rate = Float(map.rate(atSource: time))
        if abs(player.rate - rate) > 0.01 { player.rate = rate }
    }

    // MARK: Preview

    /// Draws the player through the edit: the same renderer the export uses, on the source as it plays.
    private func rebuildPreview() {
        guard phase == .ready, let asset else { return }
        var shown = edit
        if tool == .crop {
            shown.crop = .full
            shown.zooms = []
            shown.background = .none
        }
        let layout = FrameLayout(source: sourceSize, edit: shown, box: Self.previewBox)
        previewLayout = layout
        let renderer = FrameRenderer(layout: layout, edit: shown, zoom: ZoomPlan(segments: shown.zooms, cursor: cursor))
        previewStill = stillFrame.flatMap { renderer.cgImage(from: $0, atSource: playhead) }
        let frameRate = frameRate
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            let composition = await EditComposition.preview(
                asset: asset, renderer: renderer, framesPerSecond: frameRate)
            guard !Task.isCancelled, let self else { return }
            player.currentItem?.videoComposition = composition
            if !isPlaying { seek(to: playhead) }  // draws the picture that is showing again
        }
    }

    /// The tracks' volumes and mutes, as the preview plays them.
    private func updateAudioMix() {
        guard let item = player.currentItem else { return }
        let tracks = audioTracks.enumerated().map { index, track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(edit.audioSetting(index).gain, at: .zero)
            return parameters
        }
        guard !tracks.isEmpty else { return }
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks
        item.audioMix = mix
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        let (edit, url, duration, delay) = (edit, url, duration, saveDelay)
        saveTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            try? EditSidecar.save(edit, for: url, duration: duration)
        }
    }

    /// Writes the edit now, as the window closes.
    public func flush() {
        saveTask?.cancel()
        guard phase == .ready else { return }
        try? EditSidecar.save(edit, for: url, duration: duration)
    }

    /// Ends the session: stops playback and any export, and saves.
    public func close() {
        pause()
        cancelExport()
        previewTask?.cancel()
        flush()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Export

    /// Where an export goes by default: beside the source, or Topdeck's Captures folder when that can't be written.
    public func defaultFolder() -> URL {
        let beside = url.deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: beside.path) ? beside : CaptureFiles.folder
    }

    /// Exports the edit as a new file in `folder` (beside the source unless told otherwise), off the main thread.
    public func export(to destination: URL? = nil) {
        guard phase == .ready, !isExporting else { return }
        pause()
        let target =
            destination ?? ExportNaming.destination(for: url, format: edit.export.format, in: defaultFolder())
        exportState = .running(0)
        let (source, edit, cursor) = (url, edit, cursor)
        let throttle = ProgressThrottle()
        let id = UUID()
        exportID = id
        exportTask = Task { [weak self] in
            do {
                try await VideoExporter.export(source: source, edit: edit, cursor: cursor, to: target) { value in
                    guard throttle.shouldReport(value) else { return }
                    Task { @MainActor in
                        guard self?.exportID == id else { return }
                        self?.exportProgress(value)
                    }
                }
                guard self?.exportID == id else { return }
                self?.exportDone(target)
            } catch is CancellationError {
                guard self?.exportID == id else { return }
                self?.exportState = .idle
            } catch {
                guard self?.exportID == id else { return }
                self?.exportState = .failed("Couldn't export the video")
            }
        }
    }

    private func exportProgress(_ value: Double) {
        if case .running = exportState { exportState = .running(value) }
    }

    private func exportDone(_ target: URL) {
        exportState = .done(target)
        onExported?(target)
    }

    public func cancelExport() {
        exportTask?.cancel()
        exportID = nil
        if case .running = exportState { exportState = .idle }
    }

    /// Clears a finished or failed export's message.
    public func dismissExport() {
        if !isExporting { exportState = .idle }
    }
}

/// Lets a progress report through when it has moved a hundredth: an export reports on every frame.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0

    func shouldReport(_ value: Double) -> Bool {
        lock.withLock {
            guard value - last >= 0.01 || value >= 1 else { return false }
            last = value
            return true
        }
    }
}
