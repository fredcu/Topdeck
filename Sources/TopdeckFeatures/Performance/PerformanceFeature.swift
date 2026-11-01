// SPDX-License-Identifier: MIT
import Foundation
import Observation
import SwiftUI
import TopdeckCore

/// How the Mac is doing: per-core CPU, GPU, memory, disk, network, the busiest apps, temperature, and
/// the battery's health. It reads once a second while the tab is on screen and not at all otherwise:
/// no timer in the background, no alerts, and a minute of history only while it is on screen. Each rate is the difference between two
/// readings, so leaving the tab forgets the last one rather than showing a long gap as a speed.
/// The reading, which walks every process and asks IOKit, runs on its own queue so the notch's
/// animations never wait on it; only the finished snapshot comes back to the main actor.
@MainActor
@Observable
public final class PerformanceFeature: NotchFeature {
    /// One look at the Mac. Rates are nil until there are two readings to subtract.
    struct Snapshot: Equatable, Sendable {
        var efficiencyCores: [Double] = []
        var performanceCores: [Double] = []
        var gpu: Double?
        var memory: MemorySample?
        var pressure = MemoryPressure.normal
        var diskRead: Double?
        var diskWritten: Double?
        var diskFree: Int64?
        var diskTotal: Int64?
        var network: Rate?
        var topCPU: [ProcessUsage] = []
        var topMemory: [ProcessUsage] = []
        var temperatures: Temperatures?
        var battery: BatteryReport?
        var loadAverage: Double?
        var chipName: String?
        var thermal = ThermalLevel.normal
        /// "Wi-Fi", "Ethernet", or the interface's name.
        var networkInterface: String?

        var cpu: Double? {
            let cores = efficiencyCores + performanceCores
            return cores.isEmpty ? nil : cores.reduce(0, +) / Double(cores.count)
        }
    }

    public let id = FeatureID.performance
    public var phase: FeaturePhase = .stopped {
        didSet { if phase != oldValue { update() } }
    }
    private(set) var snapshot = Snapshot()
    /// The last minute of each reading, for the sparklines.
    private(set) var history = PerformanceHistory()
    /// How many processes each top list keeps: as many as the largest deck has rows for.
    nonisolated static let listedProcesses = 12

    /// The only place the system is read, one reading at a time.
    @ObservationIgnored let queue = DispatchQueue(label: "net.icuai.topdeck.performance", qos: .utility)
    @ObservationIgnored private let makeSource: () -> any SnapshotSource
    @ObservationIgnored private let interval: TimeInterval
    @ObservationIgnored private var timer: DispatchSourceTimer?
    /// Made when the tab opens and dropped when it closes, with everything it remembers.
    @ObservationIgnored private var source: (any SnapshotSource)?
    /// Counts the tab's visits, so a reading that finishes after its visit is over is thrown away.
    @ObservationIgnored private var visit = 0
    /// Whether a reading is on the queue. Ticks that find one skip, so none wait behind it, and it
    /// stays set past a stop until that reading ends, so a quick return can't start a second.
    @ObservationIgnored private var reading = false

    public convenience init() { self.init(source: { Sampler() }) }

    /// `interval` is how often to read; a test that makes its own ticks sets it far off.
    init(source: @escaping () -> any SnapshotSource, interval: TimeInterval = 1) {
        makeSource = source
        self.interval = interval
    }

    public var view: some View { PerformanceView(performance: self) }

    /// Shows `readings` as the history, the last of them as now, with no reader: for screenshots and tests.
    func preview(_ readings: [Snapshot]) {
        history = PerformanceHistory()
        for reading in readings { history.record(reading) }
        snapshot = readings.last ?? Snapshot()
    }

    /// "Wi-Fi", "Ethernet" or the interface's name, for the Mac page's Network row.
    public var networkName: String? { snapshot.networkInterface }

    /// The process using the most CPU now, for the Mac page's System row; nil while none is known or none is busy.
    public var busiestProcess: (name: String, cpu: Double)? {
        snapshot.topCPU.first.flatMap { $0.name.isEmpty ? nil : ($0.name, $0.cpu) }
    }

    /// Whether a reading is scheduled.
    var isSampling: Bool { timer != nil }

    private func update() {
        guard phase == .foreground else { return stop() }
        guard timer == nil else { return }
        source = makeSource()
        sample()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.sample() } }
        timer.resume()
        self.timer = timer
    }

    private func stop() {
        timer?.cancel()
        timer = nil
        source = nil
        visit += 1
        snapshot = Snapshot()
        history = PerformanceHistory()
    }

    /// Starts a reading on the queue unless one is still going.
    func sample() {
        guard !reading, let source else { return }
        reading = true
        let visit = visit
        queue.async { [weak self] in
            let next = source.read()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(next, visit: visit) } }
        }
    }

    private func finish(_ next: Snapshot, visit: Int) {
        reading = false
        guard visit == self.visit, next != snapshot else { return }
        snapshot = next
        history.record(next)
    }
}
