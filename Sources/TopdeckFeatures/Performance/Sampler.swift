// SPDX-License-Identifier: MIT
import Foundation

/// Takes one reading of the Mac. `PerformanceFeature` calls it from its queue, one reading at a time.
protocol SnapshotSource: AnyObject, Sendable {
    func read() -> PerformanceFeature.Snapshot
}

/// The real readings, with what a rate needs from the one before. One lives per visit to the tab, so
/// the next visit starts without it. Everything here, the temperature client included, is touched
/// only from the feature's queue.
final class Sampler: SnapshotSource, @unchecked Sendable {
    private struct Previous {
        var at: Date
        var cores: [CPUTicks]
        var disk: (read: UInt64, written: UInt64)?
        var traffic: [String: Traffic]
        var processes: [ProcessSample]
    }

    /// Set up by the first reading, so none of it happens on the main actor.
    private var layout = CoreLayout(efficiency: 0, performance: 0)
    private var sensors: TemperatureSensors?
    private var smc: SMCReader?
    private var isSetUp = false
    private var snapshot = PerformanceFeature.Snapshot()
    /// The previous reading of each counter, and when.
    private var last: Previous?
    private var spaceAge = 0

    func read() -> PerformanceFeature.Snapshot {
        if !isSetUp {
            isSetUp = true
            layout = Probes.coreLayout()
            sensors = TemperatureSensors()
            smc = SMCReader()
            snapshot.chipName = Probes.chipName()
        }
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
            next.topCPU = Self.named(ProcessUsage.topByCPU(usage, limit: PerformanceFeature.listedProcesses))
            next.topMemory = Self.named(ProcessUsage.topByMemory(usage, limit: PerformanceFeature.listedProcesses))
        }
        next.gpu = Probes.gpuUsage()
        next.memory = Probes.memory()
        next.pressure = Probes.memoryPressure()
        // Free space costs about 5 ms to work out as Finder does, and moves slowly.
        if spaceAge % 15 == 0, let space = Probes.diskSpace() {
            (next.diskFree, next.diskTotal) = (space.free, space.total)
        }
        // Which connection is in use changes rarely.
        if spaceAge % 15 == 0 { next.networkInterface = Probes.primaryInterface() }
        spaceAge += 1
        next.loadAverage = Probes.loadAverage()
        next.thermal = ThermalLevel(ProcessInfo.processInfo.thermalState)
        if sensors != nil || smc != nil {
            var temperatures = Temperatures(from: sensors?.read() ?? [])
            // The battery's SMC key is read only when the sensors gave no battery.
            temperatures.apply(
                smcGPU: smc?.gpuTemperature(), smcBattery: temperatures.battery == nil ? smc?.batteryTemperature() : nil
            )
            next.temperatures = temperatures.isEmpty ? nil : temperatures
        }
        next.battery = Probes.battery()
        last = current
        snapshot = next
        return next
    }

    private static func named(_ usage: [ProcessUsage]) -> [ProcessUsage] {
        usage.map {
            var usage = $0
            usage.name = Probes.name(of: usage.pid)
            return usage
        }
    }
}
