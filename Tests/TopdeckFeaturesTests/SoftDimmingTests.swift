// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import Testing

@testable import TopdeckFeatures

struct SoftDimmingMathTests {
    private let curve = SoftDimming.Curve(red: [0, 0.25, 1], green: [0, 0.5, 1], blue: [0, 0.75, 1])

    @Test func aLevelScalesEveryChannel() {
        let half = SoftDimming.table(from: curve, level: 0.5)
        #expect(half == SoftDimming.Curve(red: [0, 0.125, 0.5], green: [0, 0.25, 0.5], blue: [0, 0.375, 0.5]))
    }

    @Test func fullIsTheOriginalCurveItself() {
        #expect(SoftDimming.table(from: curve, level: 1) == curve)
        #expect(SoftDimming.table(from: curve, level: 7) == curve, "past 100% is 100%")
        #expect(SoftDimming.table(from: curve, level: .nan) == curve, "no number, no dimming")
        #expect(SoftDimming.table(from: curve, level: .infinity) == curve)
    }

    @Test func neverDarkerThanTheFloor() {
        #expect(SoftDimming.floor == 0.15)
        #expect(SoftDimming.clamp(0) == 0.15)
        #expect(SoftDimming.clamp(-3) == 0.15)
        #expect(SoftDimming.clamp(0.4) == 0.4)
        #expect(SoftDimming.table(from: curve, level: 0) == SoftDimming.table(from: curve, level: 0.15))
        #expect(SoftDimming.table(from: curve, level: 0).red.last == 0.15)
    }

    @Test func aMonitorIsNamedByVendorProductAndSerial() {
        #expect(SoftDimming.key(vendor: 0x10AC, product: 0xA04B, serial: 12345) == "4268-41035-12345")
        #expect(SoftDimming.key(vendor: nil, product: nil, serial: nil) == "0-0-0")
        #expect(
            SoftDimming.key(vendor: 1, product: 2, serial: 3) != SoftDimming.key(vendor: 1, product: 2, serial: 4))
    }
}

struct SoftDimmingLevelsTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "SoftDimming-\(UUID())")! }

    @Test func aLevelIsRememberedPerMonitor() {
        let defaults = defaults()
        let levels = SoftDimming.Levels(defaults: defaults)
        #expect(levels.level(for: "a") == 1, "never dimmed")
        levels.set(0.4, for: "a")
        levels.set(0.7, for: "b")
        let again = SoftDimming.Levels(defaults: defaults)
        #expect(again.level(for: "a") == 0.4)
        #expect(again.level(for: "b") == 0.7)
    }

    @Test func fullIsForgottenAndTheFloorHolds() {
        let defaults = defaults()
        let levels = SoftDimming.Levels(defaults: defaults)
        levels.set(0.4, for: "a")
        levels.set(1, for: "a")
        #expect((defaults.dictionary(forKey: SoftDimming.Levels.defaultsKey) ?? [:]).isEmpty)
        levels.set(0, for: "a")
        #expect(levels.level(for: "a") == 0.15)
        defaults.set(["a": 0.0, "b": 5.0], forKey: SoftDimming.Levels.defaultsKey)
        #expect(levels.level(for: "a") == 0.15, "a hand-edited zero is still the floor")
        #expect(levels.level(for: "b") == 1)
    }
}

/// Records what it's asked to dim; displays in `unsupported` can't be dimmed.
@MainActor
final class FakeDimmer: SoftDimmer {
    var unsupported: Set<CGDirectDisplayID> = []
    var applied: [(display: CGDirectDisplayID, level: Double)] = []
    var restored: [CGDirectDisplayID] = []
    var restoredAll = 0

    func apply(_ level: Double, to display: CGDirectDisplayID) -> Bool {
        guard !unsupported.contains(display) else { return false }
        applied.append((display, level))
        return true
    }

    func restore(_ display: CGDirectDisplayID) { restored.append(display) }
    func restoreAll() { restoredAll += 1 }
    func keepOnly(_ displays: [CGDirectDisplayID]) {}
}

@MainActor
struct SoftDimmingFeatureTests {
    final class Box: @unchecked Sendable { var channels: [CGDirectDisplayID: any DDCChannel] = [:] }

    private let box = Box()
    private let dimmer = FakeDimmer()
    private let defaults = UserDefaults(suiteName: "SoftDimmingFeature-\(UUID())")!

    private func feature(displays: [(id: CGDirectDisplayID, name: String)]) -> MonitorsFeature {
        let box = box
        return MonitorsFeature(
            backend: .init(
                displays: { displays }, channels: { ids in box.channels.filter { ids.contains($0.key) } },
                perform: { $0() }, send: { $0() }, sleepDisplays: { true }, identity: { "monitor-\($0)" },
                dimmer: dimmer),
            defaults: defaults)
    }

    private func settled(_ monitors: MonitorsFeature) async -> Bool {
        await eventually { !monitors.monitors.isEmpty && monitors.monitors.allSatisfy { $0.status != .checking } }
    }

    @Test func aMonitorThatDoesntAnswerDDCGetsABrightnessRowAtFull() async {
        let monitors = feature(displays: [(1, "Dell S3422DWG")])
        monitors.phase = .foreground
        #expect(await settled(monitors))
        let monitor = monitors.monitors[0]
        #expect(monitor.status == .ready)
        #expect(monitor.dimsPicture)
        #expect(monitor.brightness == 1)
        #expect(monitor.volume == nil)
        #expect(monitors.brightness == 1, "the Mac page's slider shows")
    }

    @Test func slidingDimsTheCurveAndIsRemembered() async {
        let monitors = feature(displays: [(1, "Dell S3422DWG")])
        monitors.phase = .foreground
        #expect(await settled(monitors))
        monitors.setBrightness(0.4)
        #expect(monitors.monitors[0].brightness == 0.4)
        #expect(dimmer.applied.last?.level == 0.4)
        monitors.set(.brightness, of: 1, to: 0)
        #expect(monitors.monitors[0].brightness == 0.15, "the floor")
        #expect(dimmer.applied.last?.level == 0.15)
        monitors.set(.volume, of: 1, to: 0.5)
        #expect(monitors.monitors[0].volume == nil)
        #expect(SoftDimming.Levels(defaults: defaults).level(for: "monitor-1") == 0.15)
        monitors.set(.brightness, of: 1, to: 1)
        #expect(SoftDimming.Levels(defaults: defaults).level(for: "monitor-1") == 1)
        #expect(dimmer.applied.last?.level == 1, "100% asks for the original curve")
    }

    @Test func aMonitorWithNoSoftwarePathIsUnavailable() async {
        dimmer.unsupported = [1]
        let monitors = feature(displays: [(1, "Gone")])
        monitors.phase = .foreground
        #expect(await settled(monitors))
        #expect(monitors.monitors[0].status == .unavailable)
        #expect(monitors.monitors[0].brightness == nil)
        #expect(monitors.brightness == nil)
        monitors.setBrightness(0.5)
        #expect(dimmer.applied.isEmpty)
    }

    @Test func aMonitorThatAnswersDDCIsNeverDimmed() async {
        box.channels = [1: FakeMonitor([.brightness: DDC.Level(current: 30, maximum: 100)])]
        SoftDimming.Levels(defaults: defaults).set(0.5, for: "monitor-1")
        let monitors = feature(displays: [(1, "Studio")])
        monitors.phase = .foreground
        #expect(await settled(monitors))
        #expect(monitors.monitors[0].brightness == 0.3)
        #expect(!monitors.monitors[0].dimsPicture)
        // Other tests post the same system notifications, so a read may have come twice.
        #expect(Set(dimmer.restored) == [1], "dimmed at launch, before DDC was known to answer; put back")
    }

    @Test func whenDDCStartsAnsweringItWinsAndTheCurveGoesBack() async {
        let monitors = feature(displays: [(1, "Dell S3422DWG")])
        monitors.phase = .foreground
        #expect(await settled(monitors))
        monitors.setBrightness(0.5)
        box.channels = [1: FakeMonitor([.brightness: DDC.Level(current: 80, maximum: 100)])]
        monitors.refresh()
        // The read ends by taking DDC over; the brightness is there a moment before.
        #expect(await eventually { !monitors.monitors[0].dimsPicture })
        #expect(monitors.monitors[0].brightness == 0.8)
        #expect(Set(dimmer.restored) == [1])
        let applied = dimmer.applied.count
        monitors.setBrightness(0.6)
        #expect(await eventually { monitors.monitors[0].brightness == 0.6 })
        #expect(dimmer.applied.count == applied, "nothing dimmed after DDC took over")
    }

    @Test func aRememberedLevelIsAppliedAtLaunchWithoutTheTabOpen() async {
        SoftDimming.Levels(defaults: defaults).set(0.5, for: "monitor-1")
        let monitors = feature(displays: [(1, "Dell S3422DWG"), (2, "Other")])
        monitors.phase = .background
        #expect(dimmer.applied.map(\.display) == [1], "only the monitor with a remembered level")
        #expect(dimmer.applied.first?.level == 0.5)
        monitors.phase = .stopped
    }

    @Test func itIsAppliedAgainAfterTheDisplaysChangeAndAfterWake() async {
        SoftDimming.Levels(defaults: defaults).set(0.5, for: "monitor-1")
        let monitors = feature(displays: [(1, "Dell S3422DWG")])
        monitors.phase = .background
        let atLaunch = dimmer.applied.count
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(await eventually { dimmer.applied.count > atLaunch })
        let afterChange = dimmer.applied.count
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await eventually { dimmer.applied.count > afterChange })
        #expect(dimmer.applied.allSatisfy { $0.display == 1 && $0.level == 0.5 })
        monitors.phase = .stopped
    }

    @Test func stoppingPutsEveryCurveBackAndStopsWatching() async {
        SoftDimming.Levels(defaults: defaults).set(0.5, for: "monitor-1")
        let monitors = feature(displays: [(1, "Dell S3422DWG")])
        monitors.phase = .foreground
        #expect(await settled(monitors))
        monitors.phase = .stopped
        #expect(dimmer.restoredAll == 1)
        let applied = dimmer.applied.count
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(dimmer.applied.count == applied)
    }
}
