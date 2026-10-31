// SPDX-License-Identifier: MIT
import AppKit
import Observation
import SwiftUI
import TopdeckCore

/// A countdown: running until `endsAt`, or paused with `remaining` left.
public struct Countdown: Equatable, Sendable {
    public var total: TimeInterval
    /// Set while running.
    public var endsAt: Date?
    /// Time left when paused.
    public var remaining: TimeInterval

    public var isRunning: Bool { endsAt != nil }

    public func remaining(at date: Date) -> TimeInterval {
        endsAt.map { max(0, $0.timeIntervalSince(date)) } ?? remaining
    }
}

/// A stopwatch: the time banked so far plus the current run, if any.
public struct Stopwatch: Equatable, Sendable {
    public private(set) var banked: TimeInterval = 0
    public private(set) var startedAt: Date?
    /// Total elapsed time at each lap, oldest first.
    public private(set) var laps: [TimeInterval] = []

    public init() {}

    public var isRunning: Bool { startedAt != nil }

    public func elapsed(at date: Date) -> TimeInterval {
        banked + (startedAt.map { date.timeIntervalSince($0) } ?? 0)
    }

    public mutating func start(at date: Date) {
        if startedAt == nil { startedAt = date }
    }

    public mutating func pause(at date: Date) {
        banked = elapsed(at: date)
        startedAt = nil
    }

    public mutating func lap(at date: Date) { laps.append(elapsed(at: date)) }

    public mutating func reset() { self = Stopwatch() }
}

/// A countdown timer, a stopwatch, and keep awake. None needs work to start or stop: a countdown is
/// one wall-clock deadline (never a per-second tick) and the stopwatch is arithmetic, so both keep
/// going across sleep and while the tab is hidden, and the display only ticks while it's on screen.
/// Keeping awake is a power assertion or two, plus a deadline when it ends by itself.
@MainActor
@Observable
public final class TimerFeature: NotchFeature {
    public enum Mode: Sendable { case countdown, stopwatch, keepAwake }

    public let id = FeatureID.timer
    public var phase: FeaturePhase = .stopped
    public var mode = Mode.countdown
    public private(set) var countdown: Countdown?
    public private(set) var stopwatch = Stopwatch()
    /// When keeping the Mac awake ends: nil while it's off, `.distantFuture` until it's turned off.
    public private(set) var awakeUntil: Date?
    /// Whether keeping awake keeps the display on too, or lets it sleep while the Mac stays up.
    public var keepScreenOn: Bool {
        didSet {
            defaults.set(keepScreenOn, forKey: Self.screenOnKey)
            if keepsAwake { _ = assertions.hold(screenOn: keepScreenOn) }
        }
    }
    /// Raised when a countdown finishes, and when keeping awake runs out.
    @ObservationIgnored public var onActivity: ((Activity) -> Void)?
    /// Shows the closed notch that the Mac is being kept awake, and for how long; nil once it isn't.
    @ObservationIgnored public var onOngoing: ((Activity?) -> Void)?
    @ObservationIgnored private var alarm: Task<Void, Never>?
    @ObservationIgnored private var assertions: PowerAssertions
    @ObservationIgnored private var awakeEnd: Task<Void, Never>?
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?
    /// Where the Mac says it's about to sleep.
    @ObservationIgnored private let workspace: NotificationCenter
    @ObservationIgnored private let defaults: UserDefaults
    /// When the Mac booted, so a stored keep awake can tell a restart from a quit.
    @ObservationIgnored private let bootTime: () -> Date?
    private static let screenOnKey = "timer.keepsScreenOn"
    private static let awakeUntilKey = "timer.awakeUntil"
    private static let awakeBootKey = "timer.awakeBoot"

    public static let presets: [TimeInterval] = [60, 180, 300, 600, 900, 1500, 2700, 3600]
    public static let awakePresets: [TimeInterval] = [1800, 3600, 7200, 14_400]

    public convenience init(
        workspace: NotificationCenter = NSWorkspace.shared.notificationCenter, defaults: UserDefaults = .standard
    ) {
        self.init(workspace: workspace, defaults: defaults, assertions: .live)
    }

    init(
        workspace: NotificationCenter, defaults: UserDefaults, assertions: PowerAssertions,
        bootTime: @escaping () -> Date? = TimerFeature.systemBootTime
    ) {
        self.bootTime = bootTime
        self.workspace = workspace
        self.defaults = defaults
        self.assertions = assertions
        // On by default: keeping the display on is what keep awake always did.
        keepScreenOn = defaults.object(forKey: Self.screenOnKey) as? Bool ?? true
    }

    public var view: some View { TimerView(timer: self) }

    // MARK: Countdown

    public func start(_ seconds: TimeInterval, now: Date = .now) {
        countdown = Countdown(total: seconds, endsAt: now.addingTimeInterval(seconds), remaining: seconds)
        scheduleAlarm()
    }

    public func pause(now: Date = .now) {
        guard var countdown, countdown.isRunning else { return }
        countdown.remaining = countdown.remaining(at: now)
        countdown.endsAt = nil
        self.countdown = countdown
        alarm?.cancel()
    }

    public func resume(now: Date = .now) {
        guard var countdown, !countdown.isRunning else { return }
        countdown.endsAt = now.addingTimeInterval(countdown.remaining)
        self.countdown = countdown
        scheduleAlarm()
    }

    public func addMinute() {
        guard var countdown else { return }
        countdown.total += 60
        countdown.remaining += 60
        countdown.endsAt = countdown.endsAt?.addingTimeInterval(60)
        self.countdown = countdown
        scheduleAlarm()
    }

    public func cancel() {
        alarm?.cancel()
        countdown = nil
    }

    /// Whether a countdown is waiting to ring.
    var alarmPending: Bool { alarm.map { !$0.isCancelled } ?? false }

    private func scheduleAlarm() {
        alarm?.cancel()
        guard let end = countdown?.endsAt else { return }
        let delay = max(0, end.timeIntervalSinceNow)
        alarm = Task { [weak self] in
            // The continuous clock keeps counting through sleep, so a countdown that ends while the
            // Mac sleeps rings on wake instead of drifting.
            do { try await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(250)) } catch { return }
            self?.ring()
        }
    }

    func ring() {
        alarm = nil
        countdown = nil
        NSSound(named: "Glass")?.play()
        onActivity?(Activity(feature: .timer, symbol: "timer", title: "Timer done", duration: .seconds(4)))
    }

    // MARK: Stopwatch

    public func toggleStopwatch(now: Date = .now) {
        if stopwatch.isRunning { stopwatch.pause(at: now) } else { stopwatch.start(at: now) }
    }

    public func lap(now: Date = .now) { stopwatch.lap(at: now) }

    public func resetStopwatch() { stopwatch.reset() }

    // MARK: Keep awake

    /// Whether the Mac is being kept awake.
    public var keepsAwake: Bool { awakeUntil != nil }

    /// Keeps the Mac awake for `seconds`, or until turned off when that's nil.
    public func keepAwake(for seconds: TimeInterval?, now: Date = .now) {
        keepAwake(seconds.map(AwakeEnd.after) ?? .never, now: now)
    }

    /// Keeps the Mac awake, and its display too with `keepScreenOn`, until `end`. Starting again
    /// replaces the end.
    public func keepAwake(_ end: AwakeEnd, now: Date = .now, calendar: Calendar = .current) {
        guard assertions.hold(screenOn: keepScreenOn) else { return }
        let until = end.deadline(from: now, calendar: calendar)
        awakeUntil = until ?? .distantFuture
        defaults.set(awakeUntil, forKey: Self.awakeUntilKey)
        defaults.set(bootTime(), forKey: Self.awakeBootKey)
        awakeEnd?.cancel()
        awakeEnd = nil
        if let until {
            let delay = max(0, until.timeIntervalSince(now))
            awakeEnd = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay), tolerance: .seconds(1)) } catch { return }
                self?.endAwake(announce: true)
            }
        }
        // Sleep that happens anyway (the lid, the Apple menu) ends it: a Mac that slept didn't need
        // it, and one that stays on after waking would drain the battery overnight.
        if sleepObserver == nil {
            sleepObserver = workspace.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.allowSleep() }
            }
        }
        onOngoing?(
            Activity(feature: .timer, symbol: "cup.and.saucer.fill", title: "Awake", duration: .zero, countdown: until))
    }

    /// Picks keep awake back up after a quit or an update, which release the assertions: runs the
    /// stored end through `keepAwake` unless it has passed or the Mac has restarted since.
    public func restoreAwake(now: Date = .now) {
        guard !keepsAwake, let until = defaults.object(forKey: Self.awakeUntilKey) as? Date else { return }
        let boot = defaults.object(forKey: Self.awakeBootKey) as? Date
        guard until > now, let boot, boot == bootTime() else { return clearStoredAwake() }
        keepAwake(for: until == .distantFuture ? nil : until.timeIntervalSince(now), now: now)
    }

    private func clearStoredAwake() {
        defaults.removeObject(forKey: Self.awakeUntilKey)
        defaults.removeObject(forKey: Self.awakeBootKey)
    }

    /// `kern.boottime`; nil if the Mac won't say.
    nonisolated static func systemBootTime() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }

    /// Adds half an hour to a timed keep awake.
    public func extendAwake(now: Date = .now) {
        guard let awakeUntil, awakeUntil != .distantFuture else { return }
        keepAwake(for: awakeUntil.timeIntervalSince(now) + 1800, now: now)
    }

    /// Lets the Mac sleep again.
    public func allowSleep() { endAwake(announce: false) }

    private func endAwake(announce: Bool) {
        guard keepsAwake else { return }
        assertions.releaseAll()
        awakeUntil = nil
        clearStoredAwake()
        awakeEnd?.cancel()
        awakeEnd = nil
        if let sleepObserver { workspace.removeObserver(sleepObserver) }
        sleepObserver = nil
        onOngoing?(nil)
        if announce {
            onActivity?(Activity(feature: .timer, symbol: "moon.zzz.fill", title: "Can sleep", duration: .seconds(3)))
        }
    }

    /// Whether any power assertion is held. For tests.
    var holdsAssertion: Bool { !assertions.held.isEmpty }
}

/// "1:05" or "1:02:03"; with `tenths`, "1:05.3". Countdowns round whole seconds up, so 0:00 means
/// done; counters round down, so elapsed plus remaining always adds up.
func formatTime(_ seconds: TimeInterval, tenths: Bool = false, roundingUp: Bool = true) -> String {
    let total = max(0, seconds)
    let whole = Int(tenths ? total : total.rounded(roundingUp ? .up : .down))
    let (hours, minutes, secs) = (whole / 3600, whole / 60 % 60, whole % 60)
    var text = String(format: "%d:%02d", minutes, secs)
    if hours > 0 { text = String(format: "%d:%02d:%02d", hours, minutes, secs) }
    if tenths { text += String(format: ".%d", Int((total * 10).rounded(.down)) % 10) }
    return text
}
