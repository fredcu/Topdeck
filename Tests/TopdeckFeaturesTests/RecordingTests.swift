// SPDX-License-Identifier: MIT
import AVFoundation
import CoreMedia
import Foundation
import IOKit.pwr_mgt
import Testing
import TopdeckCore

@testable import TopdeckFeatures

struct RecordingModelTests {
    @Test func theOptionsAreOffExceptClicksAndRemembered() {
        let defaults = UserDefaults(suiteName: "RecordingOptions-\(UUID())")!
        var options = RecordingOptions(defaults: defaults)
        #expect(!options.systemAudio && !options.microphone && options.showClicks)
        options.systemAudio = true
        options.showClicks = false
        options.save(to: defaults)
        #expect(RecordingOptions(defaults: defaults) == options)
    }

    @Test func theClockCountsWhatWasRecordedNotWhatTheWallSays() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var clock = RecordingClock()
        #expect(clock.elapsed(at: start) == 0)
        clock.begin(at: start)
        #expect(clock.elapsed(at: start + 10) == 10 && clock.isRunning)
        clock.pause(at: start + 10)
        #expect(clock.elapsed(at: start + 500) == 10 && clock.isPaused, "held, it stands still")
        clock.pause(at: start + 20)  // a second pause changes nothing
        clock.resume(at: start + 40)
        #expect(clock.elapsed(at: start + 45) == 15)
        #expect(clock.countsFrom(at: start + 45) == start + 30, "the notch counts up from here")
    }

    @Test func pausedSpansAreCutOutOfTheTimeline() {
        func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
        var timeline = RecordingPauseTimeline()
        #expect(timeline.acceptVideoFrame(at: t(100))?.seconds == 100)
        #expect(timeline.acceptVideoFrame(at: t(100)) == nil, "a frame that doesn't advance the track is refused")
        timeline.pause(at: t(101))
        #expect(timeline.outputTime(for: t(103)) == nil, "captured while paused")
        timeline.resume(at: t(105))
        #expect(timeline.outputTime(for: t(104)) == nil, "captured before the resume, delivered after it")
        #expect(timeline.outputTime(for: t(106))?.seconds == 102, "the four held seconds are gone")
        #expect(timeline.accumulatedOffset.seconds == 4)
    }

    @Test func aBigDisplayIsScaledToWhatTheEncoderTakes() {
        let laptop = RecordingEncoding.fittedSize(width: 3456, height: 2234)
        #expect(laptop.width == 3456 && laptop.height == 2234, "a 16-inch MacBook Pro records at its own size")
        let studio = RecordingEncoding.fittedSize(width: 6016, height: 3384)
        #expect(studio.width < 6016 && studio.width % 2 == 0 && studio.height % 2 == 0)
        let blocks = ((studio.width + 15) / 16) * ((studio.height + 15) / 16)
        #expect(blocks <= 34_560, "inside the 60 frames a second budget")
        #expect(abs(Double(studio.width) / Double(studio.height) - 6016.0 / 3384.0) < 0.01, "same shape")
        let odd = RecordingEncoding.fittedSize(width: 1001, height: 601)
        #expect(odd.width == 1000 && odd.height == 600)
    }

    @Test func theBitrateFollowsThePixelsWithinItsBounds() {
        #expect(RecordingEncoding.bitrate(width: 100, height: 100) == RecordingEncoding.minimumBitrate)
        #expect(RecordingEncoding.bitrate(width: 7680, height: 4320) == RecordingEncoding.maximumBitrate)
        #expect(RecordingEncoding.bitrate(width: 1920, height: 1080) == 24_883_200)
    }

    @Test func failuresAreToldApart() {
        let full = NSError(domain: AVFoundationErrorDomain, code: AVError.diskFull.rawValue)
        #expect(RecordingFailure.classify(full, hasAccess: true) == .diskFull)
        let wrapped = NSError(
            domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        #expect(RecordingFailure.classify(wrapped, hasAccess: true) == .diskFull)
        let stopped = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3821)
        #expect(RecordingFailure.classify(stopped, hasAccess: false) == .permissionRevoked)
        #expect(RecordingFailure.classify(stopped, hasAccess: true, windowExists: false) == .windowClosed)
        #expect(RecordingFailure.classify(stopped, hasAccess: true) == .streamFailed)
        let display = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3814)
        #expect(RecordingFailure.classify(display, hasAccess: true) == .displayGone)
        #expect(Set([RecordingFailure.diskFull, .windowClosed, .permissionRevoked].map(\.message)).count == 3)
    }

    @Test func recordingsAreNamedLikeMacOSNamesThem() throws {
        let zone = try #require(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let name = CaptureFiles.recordingName(window: false, at: date, timeZone: zone)
        #expect(name.hasPrefix("Screen Recording 20") && name.contains(" at "))
        #expect(CaptureFiles.recordingName(window: true, at: date, timeZone: zone).hasPrefix("Window Recording "))
        let folder = FileManager.default.temporaryDirectory.appending(path: "Rec-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try CaptureFiles.uniqueURL(named: name, extension: "mp4", in: folder)
        try Data().write(to: first)
        let second = try CaptureFiles.uniqueURL(named: name, extension: "mp4", in: folder)
        #expect(second.lastPathComponent == name + " 2.mp4")
        try Data().write(to: URL(filePath: second.path + ".partial"))
        #expect(
            try CaptureFiles.uniqueURL(named: name, extension: "mp4", in: folder).lastPathComponent == name + " 3.mp4",
            "a recording still being written holds its name")
    }

    @Test func theClosedNotchActivityFollowsTheState() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var clock = RecordingClock()
        clock.begin(at: start)
        let running = RecordingActivity.make(.recording, clock: clock, now: start + 30)
        #expect(running?.recording == .running(since: start) && running?.feature == .capture)
        clock.pause(at: start + 30)
        #expect(
            RecordingActivity.make(.paused, clock: clock, now: start + 99)?.recording == .paused(elapsed: 30),
            "held, it stands at what was recorded")
        #expect(RecordingActivity.make(.countdown(2), clock: clock, now: start)?.recording == .countdown(2))
        #expect(RecordingActivity.make(.idle, clock: clock, now: start) == nil)
        #expect(RecordingActivity.make(.stopping, clock: clock, now: start) == nil)
    }
}

struct CursorTrackTests {
    @Test func theCursorIsBetweenItsSamples() throws {
        let track = CursorTrack(samples: [.init(time: 0, x: 0, y: 0), .init(time: 2, x: 1, y: 0.5)])
        let middle = try #require(track.position(at: 1))
        #expect(abs(middle.x - 0.5) < 1e-9 && abs(middle.y - 0.25) < 1e-9)
        #expect(track.position(at: -3) == CGPoint(x: 0, y: 0) && track.position(at: 9) == CGPoint(x: 1, y: 0.5))
        #expect(CursorTrack().position(at: 1) == nil)
    }

    @Test func aPointIsAFractionFromTheTopLeft() {
        let area = CGRect(x: 100, y: 50, width: 200, height: 100)  // AppKit: y grows upward
        #expect(CursorTrack.fraction(of: CGPoint(x: 100, y: 150), in: area) == CGPoint(x: 0, y: 0), "top left")
        #expect(CursorTrack.fraction(of: CGPoint(x: 200, y: 100), in: area) == CGPoint(x: 0.5, y: 0.5))
        #expect(CursorTrack.fraction(of: CGPoint(x: 900, y: -9), in: area) == CGPoint(x: 1, y: 1), "kept inside")
    }

    @Test func aRestingPointerAddsLittle() {
        var track = CursorTrack()
        track.add(.init(time: 0, x: 0.5, y: 0.5))
        track.add(.init(time: 0.03, x: 0.50001, y: 0.5))
        track.add(.init(time: 0.5, x: 0.5, y: 0.5))
        #expect(track.samples.count == 1)
        track.add(.init(time: 2, x: 0.5, y: 0.5))  // a long rest still leaves a point
        track.add(.init(time: 2.03, x: 0.6, y: 0.5))
        #expect(track.samples.count == 3)
    }

    @Test func itIsKeptBesideTheVideoAsSmallJSON() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Cursor-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appending(path: "Screen Recording 2026-10-30 at 14.03.22.mp4")
        #expect(
            CursorTrack.url(for: video).lastPathComponent
                == "Screen Recording 2026-10-30 at 14.03.22.topdeck-cursor.json")
        var track = CursorTrack()
        for step in 0..<600 { track.add(.init(time: Double(step) / 30, x: Double(step) / 600, y: 0.25)) }
        try track.save(for: video)
        let loaded = try #require(CursorTrack.load(for: video))
        #expect(loaded.samples.count == 600 && abs(loaded.samples[300].x - 0.5) < 1e-4)
        let size = try FileManager.default.attributesOfItem(atPath: CursorTrack.url(for: video).path)[.size] as? Int
        #expect((size ?? .max) < 20_000, "twenty seconds are a few KB")
        #expect(CursorTrack.load(for: folder.appending(path: "none.mp4")) == nil)
    }
}

/// Synthetic frames through the writer: no screen, no microphone.
struct RecordingWriterTests {
    private func frame(_ width: Int, _ height: Int, shade: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), Int32(shade), CVPixelBufferGetBytesPerRow(pixels) * height)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    @Test func framesBecomeAnMP4OfTheSameSizeAndLength() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "Writer-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(url: url, width: 160, height: 90, systemAudio: false, microphone: false)
        try writer.start()
        for index in 0..<60 {
            let time = CMTime(value: CMTimeValue(1000 + index), timescale: 30)
            while !writer.isReady { try await Task.sleep(for: .milliseconds(5)) }
            writer.appendVideo(try frame(160, 90, shade: UInt8(index * 4)), at: time)
        }
        #expect(await writer.finish() == nil)
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 160, height: 90))
        let seconds = try await asset.load(.duration).seconds
        #expect(abs(seconds - 2) < 0.2, "sixty frames at thirty a second: \(seconds)")
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
    }

    @Test func aPauseLeavesNoGapInTheFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "Paused-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(url: url, width: 64, height: 64, systemAudio: false, microphone: false)
        try writer.start()
        func send(_ index: Int) async throws {
            while !writer.isReady { try await Task.sleep(for: .milliseconds(5)) }
            writer.appendVideo(try frame(64, 64, shade: 90), at: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        for index in 0..<30 { try await send(index) }  // the first second
        writer.pause(atHostTime: CMTime(value: 30, timescale: 30))
        for index in 30..<150 { try await send(index) }  // four seconds, none of them kept
        writer.resume(atHostTime: CMTime(value: 150, timescale: 30))
        for index in 150..<180 { try await send(index) }  // the last second
        #expect(await writer.finish() == nil)
        let seconds = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(seconds - 2) < 0.2, "two seconds recorded, the four held ones cut out: \(seconds)")
    }

    /// A recording that is never closed (the disk filled, the Mac lost power) still plays up to its last fragment.
    @Test func aFileThatWasNeverClosedPlaysUpToItsLastFragment() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "Open-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(url: url, width: 64, height: 64, systemAudio: false, microphone: false)
        try writer.start()
        for index in 0..<270 {  // nine seconds
            while !writer.isReady { try await Task.sleep(for: .milliseconds(5)) }
            writer.appendVideo(
                try frame(64, 64, shade: UInt8(index % 200)), at: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        try await Task.sleep(for: .milliseconds(500))
        let seconds = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(seconds >= 4, "what was written is there without the file being finished: \(seconds)")
        writer.cancel()
    }

    @Test func nothingRecordedLeavesNoFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "Empty-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(url: url, width: 64, height: 64, systemAudio: true, microphone: true)
        try writer.start()
        #expect(await writer.finish() != nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

// MARK: The controller

@MainActor
private final class FakeEngine: RecordingEngine {
    var onFailure: ((RecordingFailure) -> Void)?
    var onFirstFrame: (() -> Void)?
    var events: [String] = []
    var startError: Error?
    /// Fails while still starting, as a stream that stops the moment it begins would.
    var failsWhileStarting: RecordingFailure?
    let url: URL
    let options: RecordingOptions

    init(url: URL, options: RecordingOptions) {
        self.url = url
        self.options = options
    }

    func start() async throws {
        events.append("start")
        if let startError { throw startError }
        if let failsWhileStarting { onFailure?(failsWhileStarting) }
    }

    func pause() { events.append("pause") }
    func resume() { events.append("resume") }

    func stop() async -> URL? {
        events.append("stop")
        await Task.yield()
        try? Data("mp4".utf8).write(to: url)
        return url
    }
}

/// What the services read and write: the harness's whole world.
@MainActor
private final class World {
    var engines: [FakeEngine] = []
    var windowAlive = true
    var free: Int64 = 50_000_000_000
    var microphoneAllowed = true
    var startError: Error?
    var failsWhileStarting: RecordingFailure?
    var now = Date(timeIntervalSince1970: 1_790_000_000)
    var clicks: [CGDirectDisplayID] = []
    var clicksStopped = 0
}

@MainActor
@dynamicMemberLookup
private final class Harness {
    let folder = FileManager.default.temporaryDirectory.appending(path: "Controller-\(UUID())")
    private let world = World()
    let power = FakeAssertions()
    var ongoing: [Activity?] = []
    var said: [String] = []
    var saved: [(URL, Bool)] = []
    var counting: [Bool] = []
    /// One countdown second passes for each value sent, when `autoSeconds` is off.
    let seconds = AsyncStream<Void>.makeStream()
    let controller: RecordingController

    subscript<T>(dynamicMember path: ReferenceWritableKeyPath<World, T>) -> T {
        get { world[keyPath: path] }
        set { world[keyPath: path] = newValue }
    }

    init(autoSeconds: Bool = true) {
        let world = world
        let seconds = seconds
        var services = RecordingServices.live
        services.makeEngine = { _, options, url, _ in
            let engine = FakeEngine(url: url, options: options)
            engine.startError = world.startError
            engine.failsWhileStarting = world.failsWhileStarting
            world.engines.append(engine)
            return engine
        }
        services.startClicks = {
            world.clicks.append($0)
            return 77
        }
        services.stopClicks = { world.clicksStopped += 1 }
        services.askMicrophone = { world.microphoneAllowed }
        services.second = {
            if autoSeconds { return }
            var iterator = seconds.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        services.heartbeat = { try? await Task.sleep(for: .seconds(3600)) }
        services.windowFrame = { _ in world.windowAlive ? CGRect(x: 0, y: 0, width: 10, height: 10) : nil }
        services.displayFrame = { _ in CGRect(x: 0, y: 0, width: 100, height: 100) }
        services.freeBytes = { _ in world.free }
        services.now = { world.now }
        let folder = folder
        controller = RecordingController(
            defaults: UserDefaults(suiteName: "Controller-\(UUID())")!, folder: { folder }, services: services,
            power: power.power)
        controller.onOngoing = { [unowned self] in ongoing.append($0) }
        controller.onActivity = { [unowned self] in said.append($0.title) }
        controller.onSaved = { [unowned self] in saved.append(($0, $1)) }
        controller.onCountdownChange = { [unowned self] in counting.append($0) }
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    var engine: FakeEngine? { world.engines.last }
    var lastPhase: RecordingPhase? { ongoing.compactMap { $0 }.last?.recording }
}

@MainActor
struct RecordingControllerTests {
    @Test func aScreenRecordingRunsFromCountdownToTheSavedFile() async throws {
        let rig = Harness()
        rig.controller.begin(.screen(5))
        #expect(await eventually { rig.controller.state == .recording })
        #expect(rig.counting == [true, false], "Escape is wanted for the countdown only")
        let phases = rig.ongoing.compactMap { $0?.recording }
        #expect(phases.prefix(3) == [.countdown(3), .countdown(2), .countdown(1)])
        #expect(phases.last == .running(since: rig.now))
        #expect(rig.clicks == [5], "clicks are marked on a screen")
        #expect(rig.power.created == [.system, .display], "the display is kept awake")
        #expect(rig.engine?.events == ["start"])

        rig.now += 12
        rig.controller.stop()
        #expect(await eventually { rig.controller.state == .idle && !rig.saved.isEmpty })
        #expect(rig.engine?.events == ["start", "stop"])
        #expect(rig.saved.count == 1 && rig.saved[0].1, "saved, and the editor opens")
        #expect(rig.saved[0].0.pathExtension == "mp4" && rig.saved[0].0.lastPathComponent.hasPrefix("Screen Recording"))
        #expect(
            rig.power.held.isEmpty && rig.power.strayReleases == 0 && rig.clicksStopped >= 1,
            "the power assertions and the ring are let go")
        #expect(rig.ongoing.last == .some(nil), "the closed notch is clear")
        #expect(rig.said.isEmpty)
    }

    @Test func aWindowRecordingMarksNoClicks() async throws {
        let rig = Harness()
        rig.controller.begin(.window(9))
        #expect(await eventually { rig.controller.state == .recording })
        #expect(rig.clicks.isEmpty && rig.engine?.options.showClicks == true)
        #expect(rig.saved.isEmpty)
        rig.controller.stop()
        #expect(await eventually { rig.saved.count == 1 })
        #expect(rig.saved[0].0.lastPathComponent.hasPrefix("Window Recording"))
    }

    @Test(arguments: [false, true])
    func repeatedStopClosesTheRecordingOnce(paused: Bool) async throws {
        let rig = Harness()
        rig.controller.begin(.screen(5))
        #expect(await eventually { rig.controller.state == .recording })
        if paused { rig.controller.pause() }
        rig.controller.stop()
        rig.controller.stop()
        rig.engine?.onFailure?(.writerFailed)
        #expect(rig.controller.state == .stopping)
        #expect(await eventually { rig.controller.state == .idle && !rig.saved.isEmpty })
        #expect(rig.engine?.events.filter { $0 == "stop" }.count == 1)
        #expect(rig.saved.count == 1 && rig.saved[0].1)
        #expect(rig.said.isEmpty)
        #expect(rig.power.held.isEmpty && rig.power.strayReleases == 0)
    }

    @Test func escapeDuringTheCountdownRecordsNothing() async throws {
        let rig = Harness(autoSeconds: false)
        rig.controller.begin(.screen(5))
        #expect(await eventually { rig.controller.state == .countdown(3) })
        rig.controller.cancelCountdown()
        #expect(rig.controller.state == .idle && rig.counting == [true, false])
        #expect(rig.ongoing.last == .some(nil))
        rig.seconds.continuation.yield()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.engine == nil && rig.controller.state == .idle, "it never started")
        #expect(!rig.controller.cancelCountdown(), "and a second Escape finds nothing")
        #expect(rig.power.created.isEmpty)
    }

    @Test func theCountdownRunsThreeTwoOne() async throws {
        let rig = Harness(autoSeconds: false)
        rig.controller.begin(.screen(5))
        for left in [3, 2, 1] {
            #expect(await eventually { rig.controller.state == .countdown(left) })
            rig.seconds.continuation.yield()
        }
        #expect(await eventually { rig.controller.state == .recording })
    }

    @Test func pausingHoldsTheClockAndTheEngine() async throws {
        let rig = Harness()
        rig.controller.begin(.screen(5))
        #expect(await eventually { rig.controller.state == .recording })
        rig.now += 20
        rig.controller.handle(.pause)
        #expect(rig.controller.state == .paused && rig.engine?.events == ["start", "pause"])
        #expect(rig.lastPhase == .paused(elapsed: 20))
        rig.now += 300
        rig.controller.handle(.resume)
        #expect(rig.controller.state == .recording && rig.engine?.events == ["start", "pause", "resume"])
        #expect(rig.lastPhase == .running(since: rig.now - 20), "the held five minutes aren't counted")
        rig.controller.togglePause()
        #expect(rig.controller.state == .paused)
    }

    @Test func aSecondStartWhileOneIsOnDoesNothing() async throws {
        let rig = Harness()
        rig.controller.begin(.screen(5))
        rig.controller.begin(.screen(6))
        #expect(await eventually { rig.controller.state == .recording })
        rig.controller.begin(.window(1))
        #expect(rig.engines.count == 1)
    }

    @Test func aClosedWindowStopsCleanlyKeepsTheFileAndSaysSoOnce() async throws {
        let rig = Harness()
        rig.controller.begin(.window(9))
        #expect(await eventually { rig.controller.state == .recording })
        rig.windowAlive = false
        rig.controller.check()
        rig.controller.check()  // a second look, before the first has finished
        rig.engine?.onFailure?(.writerFailed)  // and the writer noticing too
        #expect(await eventually { rig.controller.state == .idle && !rig.saved.isEmpty })
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.saved.count == 1 && !rig.saved[0].1, "the file is kept, the editor stays shut")
        #expect(rig.said == [RecordingFailure.windowClosed.message], "told once")
        #expect(rig.engine?.events == ["start", "stop"], "closed once")
        #expect(rig.power.held.isEmpty)
    }

    @Test func aDiskThatIsFillingStopsTheRecording() async throws {
        let rig = Harness()
        rig.controller.begin(.screen(5))
        #expect(await eventually { rig.controller.state == .recording })
        rig.free = RecordingFailure.lowDiskBytes - 1
        rig.controller.check()
        #expect(await eventually { rig.controller.state == .idle && rig.saved.count == 1 })
        #expect(rig.said == [RecordingFailure.diskFull.message])
        #expect(FileManager.default.fileExists(atPath: rig.saved[0].0.path))
    }

    @Test func aRevokedPermissionFromTheEngineIsToldOnce() async throws {
        let rig = Harness()
        rig.controller.begin(.screen(5))
        #expect(await eventually { rig.controller.state == .recording })
        rig.controller.handle(.pause)
        rig.engine?.onFailure?(.permissionRevoked)
        #expect(await eventually { rig.controller.state == .idle && rig.saved.count == 1 })
        #expect(rig.said == [RecordingFailure.permissionRevoked.message])
        #expect(rig.ongoing.last == .some(nil) && rig.power.held.isEmpty)
    }

    @Test func aStartThatFailsLeavesNothingBehind() async throws {
        let rig = Harness()
        rig.startError = RecordingFailure.displayGone
        rig.controller.begin(.screen(5))
        #expect(await eventually { rig.said.count == 1 })
        #expect(rig.controller.state == .idle && rig.saved.isEmpty && rig.power.created.isEmpty)
        #expect(rig.ongoing.last == .some(nil) && rig.clicksStopped >= 1)
        rig.startError = nil
        rig.controller.begin(.screen(5))
        #expect(await eventually { rig.controller.state == .recording }, "and the next one works")
    }

    @Test func aFailureWhileStartingIsHandledOnceItHasStarted() async throws {
        let rig = Harness()
        rig.failsWhileStarting = .displayGone
        rig.controller.begin(.screen(5))
        #expect(await eventually { rig.controller.state == .idle && rig.saved.count == 1 })
        #expect(rig.said == [RecordingFailure.displayGone.message] && !rig.saved[0].1)
        #expect(rig.power.held.isEmpty)
    }

    @Test func aDeniedMicrophoneIsLeftOutAndSaidOnce() async throws {
        let rig = Harness()
        rig.microphoneAllowed = false
        rig.controller.options.microphone = true
        rig.controller.options.systemAudio = true
        rig.controller.begin(.screen(5))
        #expect(await eventually { rig.controller.state == .recording })
        #expect(rig.engine?.options.microphone == false && rig.engine?.options.systemAudio == true)
        #expect(rig.said == ["Microphone is off for Topdeck in System Settings"])
        #expect(rig.controller.options.microphone, "the choice itself is kept for when it is allowed")
    }

    @Test func theChoicesAreRememberedAndOffClicksReachTheEngine() async throws {
        let rig = Harness()
        rig.controller.options.showClicks = false
        rig.controller.begin(.screen(5))
        #expect(await eventually { rig.controller.state == .recording })
        #expect(rig.clicks.isEmpty, "no ring when clicks are off")
    }
}
