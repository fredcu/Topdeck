// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import Observation
import TopdeckCore

/// What the controller leans on outside itself, so a test can run a whole recording without a screen.
@MainActor
struct RecordingServices {
    /// A recorder for `target` writing `destination`; the last value is the window that marks clicks.
    var makeEngine: (RecordingTarget, RecordingOptions, URL, CGWindowID?) -> RecordingEngine
    /// Puts the click ring over a display; returns the window number it keeps in the picture.
    var startClicks: (CGDirectDisplayID) -> CGWindowID?
    var stopClicks: () -> Void
    /// Asks for the microphone the first time; whether it may be used.
    var askMicrophone: () async -> Bool
    /// One second of the countdown.
    var second: () async -> Void
    /// The wait between two looks at the disk and the window.
    var heartbeat: () async -> Void
    /// Where a window is now (AppKit coordinates); nil once it is gone.
    var windowFrame: (CGWindowID) -> CGRect?
    /// A display's frame (AppKit coordinates).
    var displayFrame: (CGDirectDisplayID) -> CGRect?
    /// Free bytes on the volume that holds the Captures folder.
    var freeBytes: (URL) -> Int64?
    var now: () -> Date

    static var live: RecordingServices {
        let clicks = ClickHighlight()
        return RecordingServices(
            makeEngine: { ScreenRecorder(target: $0, options: $1, destination: $2, clickWindow: $3) },
            startClicks: { id in
                guard let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return nil }
                clicks.start(on: screen)
                return clicks.windowNumber
            },
            stopClicks: { clicks.stop() },
            askMicrophone: { await MicrophoneCapturer.ask() },
            second: { try? await Task.sleep(for: .seconds(1)) },
            heartbeat: { try? await Task.sleep(for: .seconds(1)) },
            windowFrame: { RecordingWindows.frame(of: $0) },
            displayFrame: { id in NSScreen.screens.first(where: { $0.displayID == id })?.frame },
            freeBytes: { folder in
                let key = URLResourceKey.volumeAvailableCapacityKey
                return (try? folder.resourceValues(forKeys: [key]).volumeAvailableCapacity).map(Int64.init)
            },
            now: { .now })
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map {
            CGDirectDisplayID($0.uint32Value)
        }
    }
}

/// A recording from the Record tiles to the saved file: the countdown, the run with its pause, and the ending,
/// whether the user's or a failure's. A failure stops cleanly, keeps what was written and says so once.
@MainActor
@Observable
public final class RecordingController {
    public enum State: Equatable, Sendable {
        case idle
        /// The seconds left, from three.
        case countdown(Int)
        /// The countdown is over and the recorder is starting, which takes a moment.
        case starting
        case recording
        case paused
        /// The file is being closed.
        case stopping
    }

    public static let countdownSeconds = 3

    public private(set) var state: State = .idle
    /// What the next recording takes along. Remembered.
    public var options: RecordingOptions {
        didSet { if options != oldValue { options.save(to: defaults) } }
    }

    /// Whether a recording is on, from its countdown to the file being closed.
    public var isActive: Bool { state != .idle }

    /// The closed notch's activity for the recording; nil when there is none.
    @ObservationIgnored public var onOngoing: ((Activity?) -> Void)?
    /// A one-shot message: a failure, a missing permission.
    @ObservationIgnored public var onActivity: ((Activity) -> Void)?
    /// A recording was saved; `open` says whether the editor should open on it (not after a failure).
    @ObservationIgnored public var onSaved: ((URL, _ open: Bool) -> Void)?
    /// The countdown started (true) or ended (false): Escape is wanted while it runs.
    @ObservationIgnored public var onCountdownChange: ((Bool) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let folder: () -> URL
    @ObservationIgnored private let services: RecordingServices
    @ObservationIgnored private var power: PowerAssertions
    @ObservationIgnored private var clock = RecordingClock()
    @ObservationIgnored private var target: RecordingTarget?
    @ObservationIgnored private var engine: RecordingEngine?
    /// What the file's audio tracks are, for the editor's labels.
    @ObservationIgnored private var recordedAudio: [String] = []
    @ObservationIgnored private var cursor: CursorRecorder?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    /// From a press of Record to the countdown's end: a second press does nothing meanwhile.
    @ObservationIgnored private var starting = false
    /// A failure that arrived while the recorder was still starting.
    @ObservationIgnored private var earlyFailure: RecordingFailure?

    init(
        defaults: UserDefaults = .standard, folder: @escaping () -> URL = { CaptureFiles.folder },
        services: RecordingServices = .live,
        power: PowerAssertions = .live(system: "Recording the screen", display: "Recording the screen, screen on")
    ) {
        self.defaults = defaults
        self.folder = folder
        self.services = services
        self.power = power
        options = RecordingOptions(defaults: defaults)
    }

    // MARK: Starting

    /// Starts the countdown for `target`, once the user has picked it. Nothing happens while a recording is on.
    public func begin(_ target: RecordingTarget) {
        guard state == .idle, !starting else { return }
        starting = true
        countdownTask = Task { [weak self] in await self?.run(target) }
    }

    private func run(_ target: RecordingTarget) async {
        var taken = options
        if taken.microphone, await services.askMicrophone() == false {
            taken.microphone = false
            say("Microphone is off for Topdeck in System Settings", symbol: "mic.slash.fill")
        }
        onCountdownChange?(true)
        for left in stride(from: Self.countdownSeconds, to: 0, by: -1) {
            state = .countdown(left)
            publish()
            await services.second()
            if Task.isCancelled { return }
        }
        onCountdownChange?(false)
        state = .starting
        await start(target, taking: taken)
        starting = false
    }

    private func start(_ target: RecordingTarget, taking taken: RecordingOptions) async {
        let url: URL
        do {
            url = try CaptureFiles.uniqueURL(
                named: CaptureFiles.recordingName(window: target.isWindow, at: services.now()), extension: "mp4",
                in: folder())
        } catch {
            return abandon("Couldn't start recording")
        }
        var clickWindow: CGWindowID?
        if case .screen(let display) = target, taken.showClicks { clickWindow = services.startClicks(display) }
        let engine = services.makeEngine(target, taken, url, clickWindow)
        engine.onFailure = { [weak self] failure in self?.fail(failure) }
        let services = services
        cursor = CursorRecorder(area: { [target] in
            switch target {
            case .screen(let id): services.displayFrame(id)
            case .window(let id): services.windowFrame(id)
            }
        })
        engine.onFirstFrame = { [weak self] in self?.cursor?.start() }
        do {
            try await engine.start()
        } catch {
            Log.features.error("Couldn't start recording: \(error.localizedDescription, privacy: .public)")
            let access = CGPreflightScreenCaptureAccess()
            let failure = (error as? RecordingFailure) ?? .classify(error, hasAccess: access)
            return abandon(failure == .permissionRevoked ? "Allow Screen Recording" : "Couldn't start recording")
        }
        self.engine = engine
        self.target = target
        recordedAudio = (taken.systemAudio ? ["system"] : []) + (taken.microphone ? ["microphone"] : [])
        clock.begin(at: services.now())
        state = .recording
        _ = power.hold(screenOn: true)
        publish()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                await services.heartbeat()
                if Task.isCancelled { break }
                self?.check()
            }
        }
        if let early = earlyFailure {
            earlyFailure = nil
            fail(early)
        }
    }

    /// Back to nothing after a start that failed.
    private func abandon(_ message: String) {
        services.stopClicks()
        cursor = nil
        earlyFailure = nil
        state = .idle
        onOngoing?(nil)
        say(message, symbol: "exclamationmark.triangle.fill")
    }

    // MARK: Escape

    /// Escape during the countdown: nothing is recorded. False when no countdown is running.
    @discardableResult
    public func cancelCountdown() -> Bool {
        guard case .countdown = state else { return false }
        countdownTask?.cancel()
        starting = false
        onCountdownChange?(false)
        state = .idle
        onOngoing?(nil)
        return true
    }

    // MARK: Running

    public func handle(_ control: RecordingControl) {
        switch control {
        case .pause: pause()
        case .resume: resume()
        case .stop: stop()
        }
    }

    public func togglePause() {
        if state == .recording { pause() } else if state == .paused { resume() }
    }

    func pause() {
        guard state == .recording else { return }
        engine?.pause()
        cursor?.pause()
        clock.pause(at: services.now())
        state = .paused
        publish()
    }

    func resume() {
        guard state == .paused else { return }
        engine?.resume()
        cursor?.resume()
        clock.resume(at: services.now())
        state = .recording
        publish()
    }

    /// Stops: a countdown is cancelled, a recording is saved and opened.
    public func stop() {
        switch state {
        case .countdown: cancelCountdown()
        case .recording, .paused:
            state = .stopping
            Task { await finish(failure: nil) }
        default: break
        }
    }

    /// Looks at the disk and the window. Called every second while recording.
    func check() {
        guard state == .recording || state == .paused else { return }
        if case .window(let id) = target, services.windowFrame(id) == nil { return fail(.windowClosed) }
        if let free = services.freeBytes(folder()), free < RecordingFailure.lowDiskBytes { fail(.diskFull) }
    }

    /// The recording can't go on: close it cleanly, keep the file, and tell the user once.
    func fail(_ failure: RecordingFailure) {
        if state == .starting {
            earlyFailure = failure
            return
        }
        guard state == .recording || state == .paused else { return }
        state = .stopping  // a second failure (the stream and the writer both noticing) finds nothing to do
        Task { await finish(failure: failure) }
    }

    private func finish(failure: RecordingFailure?) async {
        state = .stopping
        heartbeatTask?.cancel()
        onOngoing?(nil)
        var track = cursor?.stop() ?? CursorTrack()
        cursor = nil
        track.audio = recordedAudio
        services.stopClicks()
        let url = await engine?.stop()
        engine = nil
        power.releaseAll()
        state = .idle
        if let url {
            if track.isUsable || !track.audio.isEmpty { try? track.save(for: url) }
            onSaved?(url, failure == nil)
        } else if failure == nil {
            say("Nothing was recorded", symbol: "exclamationmark.triangle.fill")
        }
        if let failure { say(failure.message, symbol: "exclamationmark.triangle.fill") }
    }

    /// For quitting: closes a recording that is on so its file is whole. Waits a few seconds at most.
    public func stopForQuit() {
        cancelCountdown()
        guard state == .recording || state == .paused else { return }
        stop()
        let end = Date.now.addingTimeInterval(3)
        while state != .idle, Date.now < end { RunLoop.main.run(until: .now.addingTimeInterval(0.05)) }
    }

    // MARK: Telling

    private func publish() {
        onOngoing?(RecordingActivity.make(state, clock: clock, now: services.now()))
    }

    private func say(_ title: String, symbol: String) {
        onActivity?(Activity(feature: .capture, symbol: symbol, title: title, duration: .seconds(4)))
    }
}

/// The closed notch's activity for a recording's state.
enum RecordingActivity {
    static func make(_ state: RecordingController.State, clock: RecordingClock, now: Date) -> Activity? {
        func activity(_ title: String, _ phase: RecordingPhase) -> Activity {
            Activity(
                feature: .capture, symbol: "record.circle", title: title, duration: .seconds(1), recording: phase)
        }
        switch state {
        case .idle, .stopping, .starting: return nil
        case .countdown(let left): return activity("Recording starts in \(left)", .countdown(left))
        case .recording: return activity("Recording", .running(since: clock.countsFrom(at: now)))
        case .paused: return activity("Recording paused", .paused(elapsed: clock.elapsed(at: now)))
        }
    }
}
