// SPDX-License-Identifier: MIT
import AppKit
import IOKit.pwr_mgt
import Testing
import TopdeckCore

@testable import TopdeckFeatures

@MainActor
struct TimerFeatureTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func aCountdownPausesAndResumesWhereItLeftOff() throws {
        let timer = TimerFeature()
        timer.start(300, now: start)
        #expect(timer.countdown?.remaining(at: start.addingTimeInterval(100)) == 200)
        timer.pause(now: start.addingTimeInterval(100))
        let paused = try #require(timer.countdown)
        #expect(!paused.isRunning && paused.remaining(at: start.addingTimeInterval(999)) == 200)
        #expect(!timer.alarmPending, "a paused countdown has no deadline")
        timer.resume(now: start.addingTimeInterval(500))
        #expect(timer.countdown?.remaining(at: start.addingTimeInterval(550)) == 150)
        #expect(timer.alarmPending)
        timer.cancel()
        #expect(timer.countdown == nil && !timer.alarmPending)
    }

    @Test func addingAMinuteExtendsTheCountdown() {
        let timer = TimerFeature()
        timer.start(60, now: start)
        timer.addMinute()
        #expect(timer.countdown?.total == 120)
        #expect(timer.countdown?.remaining(at: start) == 120)
    }

    @Test func aFinishedCountdownRingsOnceThroughItsDeadline() async throws {
        let timer = TimerFeature()
        var activities: [Activity] = []
        timer.onActivity = { activities.append($0) }
        timer.start(0.2)
        #expect(await eventually { !activities.isEmpty })
        #expect(activities.map(\.title) == ["Timer done"])
        #expect(timer.countdown == nil && !timer.alarmPending)
    }

    @Test func theStopwatchBanksTimeAcrossPausesAndRecordsLaps() {
        var watch = Stopwatch()
        watch.start(at: start)
        watch.lap(at: start.addingTimeInterval(10))
        watch.pause(at: start.addingTimeInterval(15))
        #expect(watch.elapsed(at: start.addingTimeInterval(100)) == 15, "paused time doesn't count")
        watch.start(at: start.addingTimeInterval(100))
        #expect(watch.elapsed(at: start.addingTimeInterval(105)) == 20)
        watch.lap(at: start.addingTimeInterval(105))
        #expect(watch.laps == [10, 20])
        watch.reset()
        #expect(watch == Stopwatch())
    }

    @Test func keepingAwakeHoldsItsAssertionsAndShowsInTheClosedNotchUntilTurnedOff() {
        let timer = TimerFeature()
        var ongoing: [Activity?] = []
        timer.onOngoing = { ongoing.append($0) }
        timer.keepAwake(for: nil, now: start)
        #expect(timer.keepsAwake && timer.awakeUntil == .distantFuture && timer.holdsAssertion)
        #expect(ongoing.last??.title == "Awake" && ongoing.last??.countdown == nil, "no end, so no countdown")
        timer.keepAwake(for: 3600, now: start)
        #expect(timer.awakeUntil == start + 3600 && ongoing.last??.countdown == start + 3600)
        timer.extendAwake(now: start + 600)
        #expect(timer.awakeUntil == start + 5400, "half an hour more")
        timer.allowSleep()
        #expect(!timer.keepsAwake && !timer.holdsAssertion)
        #expect(ongoing.count == 4 && ongoing.last == .some(nil), "and the closed notch lets it go")
    }

    @Test func aTimedKeepAwakeRunsOutAndSaysSo() async {
        let timer = TimerFeature()
        var activities: [Activity] = []
        timer.onActivity = { activities.append($0) }
        timer.keepAwake(for: 0.2)
        #expect(await eventually { !timer.keepsAwake })
        #expect(activities.map(\.title) == ["Can sleep"] && !timer.holdsAssertion)
    }

    @Test func sleepingAnywayEndsKeepAwake() async {
        // Its own center: tests run side by side, and a real sleep notice would reach every timer.
        let workspace = NotificationCenter()
        let timer = TimerFeature(workspace: workspace)
        timer.keepAwake(for: nil)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(await eventually { !timer.keepsAwake })
        #expect(!timer.holdsAssertion)
    }

    @Test func untilATimeEndsLaterTodayOrElseTomorrow() {
        let day = Date(timeIntervalSince1970: 100 * 86_400)
        let halfPastNine = AwakeEnd.at(hour: 9, minute: 30)
        #expect(halfPastNine.deadline(from: day + 8 * 3600, calendar: gmt) == day + 9.5 * 3600)
        #expect(halfPastNine.deadline(from: day + 10 * 3600, calendar: gmt) == day + 86_400 + 9.5 * 3600, "tomorrow")
        #expect(
            halfPastNine.deadline(from: day + 9.5 * 3600, calendar: gmt) == day + 86_400 + 9.5 * 3600,
            "on the dot means tomorrow, not now")
        #expect(AwakeEnd.at(hour: 0, minute: 0).deadline(from: day + 23.75 * 3600, calendar: gmt) == day + 86_400)
        #expect(AwakeEnd.after(90).deadline(from: day) == day + 90)
        #expect(AwakeEnd.never.deadline(from: day) == nil)
    }

    @Test func untilATimeThatDaylightSavingSkipsEndsJustAfterTheJump() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        // On 8 March 2026 New York's clocks go from 2:00 straight to 3:00.
        let evening = try #require(ISO8601DateFormatter().date(from: "2026-03-07T22:00:00-05:00"))
        let end = AwakeEnd.at(hour: 2, minute: 30).deadline(from: evening, calendar: newYork)
        #expect(end == ISO8601DateFormatter().date(from: "2026-03-08T03:00:00-04:00"))
    }

    @Test func keepingTheScreenOnIsASecondAssertionThatComesAndGoes() {
        let assertions = FakeAssertions()
        let timer = timer(assertions, screenOn: false)
        timer.keepAwake(for: nil, now: start)
        #expect(assertions.held == [.system], "the display may sleep")
        timer.keepScreenOn = true
        #expect(assertions.held == [.system, .display])
        timer.keepScreenOn = false
        #expect(assertions.held == [.system] && timer.keepsAwake, "the Mac stays awake")
        timer.allowSleep()
        #expect(assertions.held.isEmpty && !timer.holdsAssertion)
        #expect(assertions.created == [.system, .display] && assertions.strayReleases == 0)
    }

    @Test func theScreenChoiceIsRememberedAndHoldsNothingWhileAsleep() throws {
        let defaults = try #require(UserDefaults(suiteName: "TimerTests-\(UUID())"))
        let assertions = FakeAssertions()
        let timer = TimerFeature(workspace: NotificationCenter(), defaults: defaults, assertions: assertions.power)
        #expect(timer.keepScreenOn, "on by default, as keep awake always was")
        timer.keepScreenOn = false
        #expect(assertions.created.isEmpty)
        let relaunched = TimerFeature(workspace: NotificationCenter(), defaults: defaults, assertions: assertions.power)
        #expect(!relaunched.keepScreenOn)
    }

    @Test func startingAgainReplacesTheEndButNotTheAssertions() {
        let assertions = FakeAssertions()
        let timer = timer(assertions)
        timer.keepAwake(for: 3600, now: start)
        timer.keepAwake(.at(hour: 9, minute: 0), now: start, calendar: gmt)
        #expect(timer.awakeUntil == Date(timeIntervalSince1970: 9 * 3600), "start is 0:16 on the first day")
        timer.keepAwake(for: nil, now: start)
        #expect(timer.awakeUntil == .distantFuture)
        #expect(assertions.created == [.system, .display], "one of each, however often it starts")
        timer.allowSleep()
        #expect(assertions.held.isEmpty && assertions.strayReleases == 0)
    }

    @Test func keepingAwakeUntilATimeRunsOutAndReleasesEveryAssertion() async {
        let assertions = FakeAssertions()
        let timer = timer(assertions)
        var activities: [Activity] = []
        timer.onActivity = { activities.append($0) }
        let nine = Date(timeIntervalSince1970: 9 * 3600)
        timer.keepAwake(.at(hour: 9, minute: 0), now: nine - 0.2, calendar: gmt)
        #expect(timer.awakeUntil == nine)
        #expect(await eventually { !timer.keepsAwake })
        #expect(activities.map(\.title) == ["Can sleep"])
        #expect(assertions.held.isEmpty && assertions.created.count == 2 && assertions.strayReleases == 0)
    }

    @Test func sleepingAnywayReleasesEveryAssertion() async {
        let assertions = FakeAssertions()
        let workspace = NotificationCenter()
        let timer = timer(assertions, workspace: workspace)
        timer.keepAwake(for: 3600)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(await eventually { !timer.keepsAwake })
        #expect(assertions.held.isEmpty && assertions.strayReleases == 0)
    }

    @Test func aRefusedAssertionDoesNotStartKeepingAwake() {
        let assertions = FakeAssertions()
        assertions.refuses = true
        let timer = timer(assertions)
        timer.keepAwake(for: nil)
        #expect(!timer.keepsAwake && assertions.held.isEmpty)
    }

    /// A calendar on GMT, so the tests read the same in every time zone.
    private var gmt: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    /// Its own sleep notices and defaults: tests run side by side.
    private func timer(
        _ assertions: FakeAssertions, screenOn: Bool = true, workspace: NotificationCenter = NotificationCenter()
    ) -> TimerFeature {
        let defaults = UserDefaults(suiteName: "TimerTests-\(UUID())") ?? .standard
        defaults.set(screenOn, forKey: "timer.keepsScreenOn")
        return TimerFeature(workspace: workspace, defaults: defaults, assertions: assertions.power)
    }

    @Test func timesAreFormattedForHumans() {
        #expect(formatTime(0) == "0:00")
        #expect(formatTime(59.2) == "1:00", "countdowns round up so 0:00 means done")
        #expect(formatTime(59.8, roundingUp: false) == "0:59", "counters round down")
        #expect(formatTime(3725) == "1:02:05")
        #expect(formatTime(65.37, tenths: true) == "1:05.3")
    }
}

/// Hands out numbered power assertions, and keeps track of which are still held.
final class FakeAssertions {
    private(set) var created: [PowerAssertions.Kind] = []
    /// Releases of an assertion that wasn't held, which would mean one was released twice.
    private(set) var strayReleases = 0
    var refuses = false
    private var live: [IOPMAssertionID: PowerAssertions.Kind] = [:]

    var held: Set<PowerAssertions.Kind> { Set(live.values) }

    var power: PowerAssertions {
        PowerAssertions(
            create: { [self] kind in
                guard !refuses else { return nil }
                created.append(kind)
                let id = IOPMAssertionID(created.count)
                live[id] = kind
                return id
            },
            release: { [self] id in
                if live.removeValue(forKey: id) == nil { strayReleases += 1 }
            })
    }
}
