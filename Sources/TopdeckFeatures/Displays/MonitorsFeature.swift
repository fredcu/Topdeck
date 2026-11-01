// SPDX-License-Identifier: MIT
// Display sleep adapted from MacTools at 9197035: Plugins/DisplaySleep/Sources/DisplaySleepPlugin.swift.
// Apache License 2.0; changed for Topdeck. See THIRD_PARTY_NOTICES.md.
import AppKit
import Observation
import SwiftUI
import TopdeckCore

/// External monitors' brightness and volume over DDC/CI, the protocol their own buttons use, and
/// putting every display to sleep at once. A monitor that doesn't answer DDC (a dock's hub may not pass
/// it on) has its picture dimmed in software instead, with no volume; one that can't be dimmed either
/// shows as unavailable. Reads each monitor when the tab comes on screen, since its buttons may have
/// changed it meanwhile. A dimmed monitor is dimmed again after the displays change and after wake, and
/// every curve is put back when the feature stops.
@MainActor
@Observable
public final class MonitorsFeature: NotchFeature {
    public struct Monitor: Identifiable, Equatable, Sendable {
        public enum Status: Equatable, Sendable { case checking, ready, unavailable }

        public let id: CGDirectDisplayID
        public let name: String
        public var status = Status.checking
        /// 0...1, or nil when the monitor doesn't have the control.
        public var brightness: Double?
        public var volume: Double?
        /// Whether `brightness` dims the picture, since the monitor doesn't answer DDC.
        public var dimsPicture = false

        public init(id: CGDirectDisplayID, name: String) {
            self.id = id
            self.name = name
        }

        func level(_ control: DDC.Control) -> Double? {
            switch control {
            case .brightness: brightness
            case .volume: volume
            }
        }

        mutating func setLevel(_ control: DDC.Control, _ value: Double?) {
            switch control {
            case .brightness: brightness = value
            case .volume: volume = value
            }
        }
    }

    /// The external displays and the DDC line of each that has one.
    struct Backend {
        var displays: @MainActor () -> [(id: CGDirectDisplayID, name: String)]
        var channels: @Sendable ([CGDirectDisplayID]) async -> [CGDirectDisplayID: any DDCChannel]
        var perform: @Sendable (@escaping @Sendable () -> DDC.Level?) async -> DDC.Level?
        var send: @Sendable (@escaping @Sendable () -> Bool) async -> Bool
        var sleepDisplays: @Sendable () async -> Bool
        /// What names a monitor in the remembered dimming levels.
        var identity: @MainActor (CGDirectDisplayID) -> String = { "\($0)" }
        var dimmer: any SoftDimmer = NoDimmer()

        static var system: Backend {
            Backend(
                displays: {
                    NSScreen.screens.compactMap { screen in
                        let key = NSDeviceDescriptionKey("NSScreenNumber")
                        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
                        let id = CGDirectDisplayID(number.uint32Value)
                        return CGDisplayIsBuiltin(id) != 0 ? nil : (id, screen.localizedName)
                    }
                },
                channels: { ids in await SystemDDC.perform { SystemDDC.channels(for: ids) } },
                perform: { await SystemDDC.perform($0) },
                send: { await SystemDDC.perform($0) },
                sleepDisplays: { await Subprocess.run("/usr/bin/pmset", ["displaysleepnow"]).status == 0 },
                identity: { display in
                    let identity = SystemDDC.identity(of: display)
                    return SoftDimming.key(vendor: identity.vendor, product: identity.product, serial: identity.serial)
                },
                dimmer: SystemGamma())
        }
    }

    private struct Key: Hashable {
        let monitor: CGDirectDisplayID
        let control: DDC.Control
    }

    public let id = FeatureID.monitors
    public var phase: FeaturePhase = .stopped {
        didSet {
            guard phase != oldValue else { return }
            let dimmed = oldValue == .stopped && startWatching()
            if phase == .foreground || dimmed { refresh() }
            if phase == .stopped {
                stopWatching()
                release()
            }
        }
    }
    public private(set) var monitors: [Monitor] = []
    /// False until the first look for monitors finishes, so the tab doesn't flash "none".
    public private(set) var hasLooked = false

    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private var channels: [CGDirectDisplayID: any DDCChannel] = [:]
    @ObservationIgnored private var levels: [Key: DDC.Level] = [:]
    @ObservationIgnored private var gates: [Key: LatestValueGate<UInt16>] = [:]
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    @ObservationIgnored private let dimLevels: SoftDimming.Levels
    /// Monitors that answered DDC since the feature started; DDC wins over a remembered dimming level.
    @ObservationIgnored private var answeringDDC: Set<CGDirectDisplayID> = []
    /// Bumped by each look and by stopping, so a look that finishes late is dropped.
    @ObservationIgnored private var generation = 0

    public convenience init() { self.init(backend: .system) }

    init(backend: Backend, defaults: UserDefaults = .standard) {
        self.backend = backend
        dimLevels = SoftDimming.Levels(defaults: defaults)
    }

    public var view: some View { MonitorsView(monitors: self) }

    /// Dims the remembered monitors now, and again whenever the displays change or wake: macOS may put
    /// their own curve back. Watches in the background too, since the dimming has to hold off screen.
    /// True if it dimmed any.
    private func startWatching() -> Bool {
        let events: [(NotificationCenter, Notification.Name)] = [
            (.default, NSApplication.didChangeScreenParametersNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification),
        ]
        observers = events.map { center, name in
            (
                center,
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.displaysChanged() }
                }
            )
        }
        return dimRemembered()
    }

    private func stopWatching() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    private func displaysChanged() {
        // A dimmed monitor is looked at again even off screen, in case DDC answers now.
        let dimmed = dimRemembered()
        if dimmed || phase == .foreground { refresh() }
    }

    /// Dims each connected monitor that has a remembered level, unless it answered DDC. True if any was.
    private func dimRemembered() -> Bool {
        let displays = backend.displays()
        backend.dimmer.keepOnly(displays.map(\.id))
        var dimmed = false
        for display in displays where !answeringDDC.contains(display.id) {
            let level = dimLevels.level(for: backend.identity(display.id))
            if level < 1, backend.dimmer.apply(level, to: display.id) { dimmed = true }
        }
        return dimmed
    }

    private func release() {
        backend.dimmer.restoreAll()
        answeringDDC = []
        generation += 1
        monitors = []
        channels = [:]
        levels = [:]
        gates = [:]
        hasLooked = false
    }

    /// Finds the external monitors again and reads each one.
    func refresh() {
        generation += 1
        let generation = generation
        let displays = backend.displays()
        // Known monitors keep their last values while they're read again.
        monitors = displays.map { display in
            monitors.first { $0.id == display.id } ?? Monitor(id: display.id, name: display.name)
        }
        Task {
            let channels = await backend.channels(displays.map(\.id))
            guard generation == self.generation else { return }
            self.channels = channels
            hasLooked = true
            for display in displays {
                await read(display.id, channel: channels[display.id], generation: generation)
            }
        }
    }

    private func read(_ id: CGDirectDisplayID, channel: (any DDCChannel)?, generation: Int) async {
        var found = false
        for control in DDC.Control.allCases {
            var level: DDC.Level?
            if let channel { level = await backend.perform { channel.read(control) } }
            guard generation == self.generation, let index = monitors.firstIndex(where: { $0.id == id }) else {
                return
            }
            let key = Key(monitor: id, control: control)
            // A drag that started while this read was out wins.
            if gates[key]?.sending != nil {
                found = true
                continue
            }
            levels[key] = level
            monitors[index].setLevel(control, level?.fraction)
            found = found || level != nil
        }
        guard let index = monitors.firstIndex(where: { $0.id == id }) else { return }
        if found {
            answeringDDC.insert(id)
            // The curve may have been dimmed at launch, before DDC was known to answer.
            backend.dimmer.restore(id)
            monitors[index].dimsPicture = false
            monitors[index].status = .ready
            return
        }
        answeringDDC.remove(id)
        // No DDC: dim the picture instead, at the level remembered for this monitor.
        let level = dimLevels.level(for: backend.identity(id))
        let dims = backend.dimmer.apply(level, to: id)
        monitors[index].dimsPicture = dims
        monitors[index].brightness = dims ? level : nil
        monitors[index].status = dims ? .ready : .unavailable
    }

    /// Sets a monitor's brightness or volume, 0...1. The slider moves at once; the monitor follows.
    func set(_ control: DDC.Control, of id: CGDirectDisplayID, to fraction: Double) {
        if let index = monitors.firstIndex(where: { $0.id == id }), monitors[index].dimsPicture {
            if control == .brightness { dim(index, to: fraction) }
            return
        }
        let key = Key(monitor: id, control: control)
        guard let level = levels[key], let channel = channels[id],
            let index = monitors.firstIndex(where: { $0.id == id })
        else { return }
        let value = level.value(for: fraction)
        monitors[index].setLevel(control, DDC.Level(current: value, maximum: level.maximum).fraction)
        levels[key]?.current = value
        if let now = gates[key, default: LatestValueGate()].submit(value) {
            send(now, control, to: channel, key: key)
        }
    }

    /// Dims a monitor's picture to `fraction`, not below the floor, and remembers it.
    private func dim(_ index: Int, to fraction: Double) {
        let level = SoftDimming.clamp(fraction)
        guard backend.dimmer.apply(level, to: monitors[index].id) else { return }
        monitors[index].brightness = level
        dimLevels.set(level, for: backend.identity(monitors[index].id))
    }

    /// The brightness of the first external monitor that has the control, 0...1, for the Mac page's slider.
    public var brightness: Double? { monitors.lazy.compactMap(\.brightness).first }

    /// Sets every external monitor's brightness that has the control, 0...1.
    public func setBrightness(_ fraction: Double) {
        for monitor in monitors where monitor.brightness != nil { set(.brightness, of: monitor.id, to: fraction) }
    }

    /// Sets a monitor's volume, 0...1, for the Sound tab.
    public func setVolume(_ fraction: Double, of id: CGDirectDisplayID) { set(.volume, of: id, to: fraction) }

    private func send(_ value: UInt16, _ control: DDC.Control, to channel: any DDCChannel, key: Key) {
        let generation = generation
        Task {
            let sent = await backend.send { channel.write(control, value: value) }
            if !sent { Log.features.info("DDC: a monitor didn't take a new \(control.rawValue, privacy: .public)") }
            guard generation == self.generation else { return }
            if let next = gates[key]?.finished() { send(next, control, to: channel, key: key) }
        }
    }

    /// Puts every display to sleep, as if it had been idle; the Mac stays awake.
    public func sleepDisplays() {
        Task {
            if await !backend.sleepDisplays() { Log.features.error("Couldn't put the displays to sleep") }
        }
    }
}
