// SPDX-License-Identifier: MIT
import Foundation
import Testing
import TopdeckCore

@testable import TopdeckFeatures

@MainActor
struct PerformanceTests {
    @Test func aCoresLoadIsItsBusyShareOfTheTimeSinceTheLastReading() {
        let before = CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let after = CPUTicks(user: 130, system: 60, idle: 860, nice: 50)
        #expect(after.usage(since: before) == 40)  // 40 busy, 60 idle
        #expect(after.usage(since: after) == nil, "no time passed")
    }

    @Test func loadsNeedTheSameCoresInBothReadings() {
        let a = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let b = CPUTicks(user: 50, system: 0, idle: 50, nice: 0)
        #expect(CPUTicks.loads(from: [a, a], to: [b, a]) == [50, 0])
        #expect(CPUTicks.loads(from: [a], to: [b, b]).isEmpty)
    }

    @Test func efficiencyCoresComeFirst() {
        let split = CoreLayout(efficiency: 2, performance: 3).split([1, 2, 3, 4, 5])
        #expect(split.efficiency == [1, 2])
        #expect(split.performance == [3, 4, 5])
        #expect(CoreLayout(efficiency: 0, performance: 2).split([7, 8]).efficiency.isEmpty)
    }

    @Test func memoryPressureFollowsTheKernelsLevels() {
        #expect(MemoryPressure(level: 1) == .normal)
        #expect(MemoryPressure(level: 2) == .warning)
        #expect(MemoryPressure(level: 4) == .critical)
        #expect(MemoryPressure(level: 0) == .normal)
    }

    @Test func aCounterThatWentDownIsAResetNotARate() {
        #expect(perSecond(from: 1_000, to: 3_000, seconds: 2) == 1_000)
        #expect(perSecond(from: 3_000, to: 1_000, seconds: 2) == 0)
        #expect(perSecond(from: 1, to: 2, seconds: 0) == 0)
    }

    @Test func processesNeedToBeInBothReadingsAndKeepTheirPID() {
        let before = [
            ProcessSample(pid: 1, cpuSeconds: 10, memory: 100), ProcessSample(pid: 2, cpuSeconds: 50, memory: 300),
            ProcessSample(pid: 4, cpuSeconds: 1, memory: 1),
        ]
        let after = [
            ProcessSample(pid: 1, cpuSeconds: 11, memory: 100),  // one core for the whole second
            ProcessSample(pid: 2, cpuSeconds: 5, memory: 300),  // PID recycled
            ProcessSample(pid: 3, cpuSeconds: 9, memory: 200),  // new
            ProcessSample(pid: 4, cpuSeconds: 1.002, memory: 5),  // idle
        ]
        let usage = ProcessUsage.cpu(from: before, to: after, seconds: 1)
        #expect(usage.map(\.pid) == [1, 4])
        #expect(ProcessUsage.topByCPU(usage).map(\.pid) == [1], "0.2% is not worth a row")
        #expect(ProcessUsage.topByMemory(usage, limit: 1).map(\.pid) == [1])
    }

    @Test func batteryHealthIsTodaysCapacityAgainstNew() {
        var battery = BatteryReport()
        battery.apply(registry: [
            "CycleCount": 312, "BatteryData": ["DesignCapacity": 6_000, "NominalChargeCapacity": 5_130],
        ])
        #expect(battery.health == 86)  // 85.5 rounds up
        #expect(battery.cycleCount == 312)

        var intel = BatteryReport()
        intel.apply(registry: ["DesignCapacity": 5_000, "AppleRawMaxCapacity": 5_200])
        #expect(intel.health == 100, "a fresh battery can read over its design capacity")

        #expect(BatteryReport().health == nil)
    }

    @Test func thePowerSourceGivesChargeAndPlug() {
        let battery = BatteryReport(powerSource: [
            "Current Capacity": 57, "Max Capacity": 100, "Is Charging": true, "Power Source State": "AC Power",
        ])
        #expect(battery.percent == 57)
        #expect(battery.isCharging && battery.isPluggedIn)
    }

    @Test func temperaturesKeepSaneChipSensorsAndLeaveOutCalibration() {
        let temperatures = Temperatures(
            from: [
                ("PMU tdie1", 40), ("PMU tdie2", 50), ("PMU tdev1", 0), ("PMU tcal", 90), ("NAND CH0 temp", 31),
                ("gas gauge battery", 29), ("gas gauge battery", 30), ("PMU tdie3", 400),
            ])
        #expect(temperatures.chip == 45)
        #expect(temperatures.chipHottest == 50)
        #expect(temperatures.ssd == 31)
        #expect(temperatures.battery == 30)
        #expect(Temperatures(from: []).isEmpty)
    }

    @Test func onlyAVisibleTabSamples() {
        let feature = PerformanceFeature()
        feature.phase = .background
        #expect(!feature.isSampling)
        feature.phase = .foreground
        #expect(feature.isSampling)
        #expect(feature.snapshot.cpu == nil, "needs a second reading for a load")
        feature.phase = .background
        #expect(!feature.isSampling)
        #expect(feature.snapshot == PerformanceFeature.Snapshot(), "nothing kept for a long gap")
    }

    @Test func theSystemAnswers() {
        #expect(!Probes.coreTicks().isEmpty)
        #expect(Probes.memory()?.used ?? 0 > 0)
        #expect(Probes.diskSpace()?.total ?? 0 > 0)
        #expect(!Probes.processes().isEmpty)
    }
}
