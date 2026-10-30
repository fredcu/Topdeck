// SPDX-License-Identifier: MIT
import Foundation
import Observation
import SwiftUI
import TopdeckCore

/// How the Mac is doing: per-core CPU, GPU, memory, disk, network, the busiest apps, temperature, and
/// the battery's health. It reads once a second while the tab is on screen and not at all otherwise:
/// no timer in the background, no alerts, no history. Each rate is the difference between two
/// readings, so leaving the tab forgets the last one rather than showing a long gap as a speed.
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

    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var layout = CoreLayout(efficiency: 0, performance: 0)
    @ObservationIgnored private var sensors: TemperatureSensors?
    /// The previous reading of each counter, and when.
    @ObservationIgnored private var last: Previous?
    @ObservationIgnored private var spaceAge = 0

    private struct Previous {
        var at: Date
        var cores: [CPUTicks]
        var disk: (read: UInt64, written: UInt64)?
        var traffic: [String: Traffic]
        var processes: [ProcessSample]
    }

    public init() {}

    public var view: some View { PerformanceView(performance: self) }

    /// Whether a reading is scheduled.
    var isSampling: Bool { timer != nil }

    private func update() {
        guard phase == .foreground else { return stop() }
        guard timer == nil else { return }
        layout = Probes.coreLayout()
        sensors = TemperatureSensors()
        sample()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.sample() } }
        timer.resume()
        self.timer = timer
    }

    private func stop() {
        timer?.cancel()
        timer = nil
        sensors = nil
        last = nil
        spaceAge = 0
        snapshot = Snapshot()
    }

    private func sample() {
        let now = Date.now
        let current = Previous(
            at: now, cores: Probes.coreTicks(), disk: Probes.diskTotals(), traffic: InterfaceCounters.read(),
            processes: Probes.processes())
        var next = snapshot
        if let last {
            let seconds = now.timeIntervalSince(last.at)
            let loads = CPUTicks.loads(from: last.cores, to: current.cores)
            (next.efficiencyCores, next.performanceCores) = layout.split(loads)
            if let before = last.disk, let after = current.disk {
                next.diskRead = perSecond(from: before.read, to: after.read, seconds: seconds)
                next.diskWritten = perSecond(from: before.written, to: after.written, seconds: seconds)
            }
            if seconds > 0 {
                let moved = InterfaceCounters.moved(from: last.traffic, to: current.traffic)
                next.network = Rate(down: Double(moved.down) / seconds, up: Double(moved.up) / seconds)
            }
            let usage = ProcessUsage.cpu(from: last.processes, to: current.processes, seconds: seconds)
            next.topCPU = Self.named(ProcessUsage.topByCPU(usage))
            next.topMemory = Self.named(ProcessUsage.topByMemory(usage))
        }
        next.gpu = Probes.gpuUsage()
        next.memory = Probes.memory()
        next.pressure = Probes.memoryPressure()
        // Free space costs about 5 ms to work out as Finder does, and moves slowly.
        if spaceAge % 15 == 0, let space = Probes.diskSpace() {
            (next.diskFree, next.diskTotal) = (space.free, space.total)
        }
        spaceAge += 1
        if let sensors {
            let temperatures = Temperatures(from: sensors.read())
            next.temperatures = temperatures.isEmpty ? nil : temperatures
        }
        next.battery = Probes.battery()
        last = current
        if next != snapshot { snapshot = next }
    }

    private static func named(_ usage: [ProcessUsage]) -> [ProcessUsage] {
        usage.map {
            var usage = $0
            usage.name = Probes.name(of: usage.pid)
            return usage
        }
    }
}
