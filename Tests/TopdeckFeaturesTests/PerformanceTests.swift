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

    @Test func aReadingThatEndsWhileTheTabIsOnScreenIsShown() async {
        let source = HeldReading(cpu: 40)
        let feature = PerformanceFeature(source: { source }, interval: 3600)
        feature.phase = .foreground
        source.waitUntilReading()
        #expect(feature.snapshot.cpu == nil, "nothing until the reading is done")
        source.release()
        await feature.settle()
        #expect(feature.snapshot.cpu == 40)
        feature.phase = .background
    }

    @Test func aReadingThatEndsAfterTheTabLeftIsNotShown() async {
        let source = HeldReading(cpu: 40)
        let feature = PerformanceFeature(source: { source }, interval: 3600)
        feature.phase = .foreground
        source.waitUntilReading()
        feature.phase = .background
        source.release()
        await feature.settle()
        #expect(feature.snapshot == PerformanceFeature.Snapshot())
    }

    @Test func readingsNeitherOverlapNorQueue() async {
        let source = HeldReading(cpu: 10)
        let feature = PerformanceFeature(source: { source }, interval: 3600)
        feature.phase = .foreground
        source.waitUntilReading()
        for _ in 0..<5 { feature.sample() }
        source.release()
        await feature.settle()
        #expect(source.started == 1, "ticks during a reading are skipped, not saved for later")
        feature.sample()
        source.waitUntilReading()
        source.release()
        await feature.settle()
        #expect(source.started == 2)
        #expect(!source.overlapped)
        feature.phase = .background
    }

    @Test func comingBackNeverSeesTheLastVisitOrStartsASecondReading() async {
        let sources = [HeldReading(cpu: 10), HeldReading(cpu: 20)]
        var made = 0
        let feature = PerformanceFeature(
            source: {
                defer { made += 1 }
                return sources[made]
            }, interval: 3600)
        feature.phase = .foreground
        sources[0].waitUntilReading()
        feature.phase = .background
        feature.phase = .foreground
        #expect(sources[1].started == 0, "the first reading is still going")
        sources[0].release()
        await feature.settle()
        #expect(feature.snapshot == PerformanceFeature.Snapshot(), "the first visit's reading is thrown away")
        feature.sample()
        sources[1].waitUntilReading()
        sources[1].release()
        await feature.settle()
        #expect(feature.snapshot.cpu == 20)
        #expect(!sources[0].overlapped && !sources[1].overlapped)
        feature.phase = .background
    }

    @Test func theSystemAnswers() {
        #expect(!Probes.coreTicks().isEmpty)
        #expect(Probes.memory()?.used ?? 0 > 0)
        #expect(Probes.diskSpace()?.total ?? 0 > 0)
        #expect(!Probes.processes().isEmpty)
    }
}

extension PerformanceFeature {
    /// Waits until the reading on the queue has ended and its result has been handled.
    fileprivate func settle() async {
        queue.sync {}
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
}

/// A reading that stays on the queue until the test lets it go, and notices if two run at once.
private final class HeldReading: SnapshotSource, @unchecked Sendable {
    private let cpu: Double
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private var running = 0
    private var count = 0
    private var both = false

    init(cpu: Double) { self.cpu = cpu }

    var started: Int { lock.withLock { count } }
    var overlapped: Bool { lock.withLock { both } }

    func read() -> PerformanceFeature.Snapshot {
        lock.withLock {
            count += 1
            running += 1
            if running > 1 { both = true }
        }
        entered.signal()
        gate.wait()
        lock.withLock { running -= 1 }
        var snapshot = PerformanceFeature.Snapshot()
        snapshot.performanceCores = [cpu]
        return snapshot
    }

    func waitUntilReading() { #expect(entered.wait(timeout: .now() + 5) == .success) }
    func release() { gate.signal() }
}

/// A reader that always sees the same Mac.
private final class QuietMac: SnapshotSource, @unchecked Sendable {
    func read() -> PerformanceFeature.Snapshot { PerformanceFeature.Snapshot() }
}

struct MacPageTests {
    @Test func aRingKeepsTheLatestValuesOldestFirst() {
        var ring = RingBuffer(capacity: 3)
        #expect(ring.values.isEmpty)
        for value in [1.0, 2] { ring.append(value) }
        #expect(ring.values == [1, 2])
        for value in [3.0, 4, 5] { ring.append(value) }
        #expect(ring.values == [3, 4, 5], "the oldest went when it was full")
        #expect(RingBuffer(capacity: 0).capacity == 1)
    }

    @MainActor @Test func theHistoryKeepsAMinuteAndStartsOverWhenTheTabIsLeft() {
        let performance = PerformanceFeature(source: { QuietMac() }, interval: 3600)
        var reading = PerformanceFeature.Snapshot()
        reading.efficiencyCores = [40]
        reading.network = Rate(down: 3000, up: 500)
        reading.memory = MemorySample(active: 8e9, wired: 4e9, compressed: 0, total: 24e9)
        performance.preview((0..<75).map { _ in reading })
        #expect(performance.history.cpu.values.count == 60)
        #expect(performance.history.cpu.values.last == 40 && performance.history.network.values.last == 3500)
        #expect(performance.history.memory.values.last == 50)
        #expect(performance.history.battery.values.isEmpty, "no battery, nothing to draw")
        performance.phase = .foreground
        performance.phase = .stopped
        #expect(performance.history.cpu.values.isEmpty, "off screen it keeps nothing")
    }

    @Test func aRateThatIsNotKnownYetIsLeftOutOfTheHistory() {
        var history = PerformanceHistory()
        history.record(PerformanceFeature.Snapshot())
        #expect(history.network.values.isEmpty && history.disk.values.isEmpty && history.cpu.values.isEmpty)
    }

    @Test func theTableSortsByTheHeaderClicked() {
        var snapshot = PerformanceFeature.Snapshot()
        let a = ProcessUsage(pid: 1, cpu: 9, memory: 100, name: "Zed")
        let b = ProcessUsage(pid: 2, cpu: 5, memory: 900, name: "Alpha")
        let c = ProcessUsage(pid: 3, cpu: 1, memory: 500, name: "mid")
        snapshot.topCPU = [a, b]
        snapshot.topMemory = [b, c]
        #expect(ProcessSort.cpu.rows(in: snapshot, limit: 5).map(\.pid) == [1, 2])
        #expect(ProcessSort.memory.rows(in: snapshot, limit: 5).map(\.pid) == [2, 3])
        #expect(ProcessSort.name.rows(in: snapshot, limit: 5).map(\.name) == ["Alpha", "mid", "Zed"])
        #expect(
            ProcessSort.cpu.rows(in: snapshot, limit: 1).count == 1
                && ProcessSort.cpu.rows(in: snapshot, limit: 0).isEmpty)
    }

    @Test func theLineOfTheSparklineRunsOverItsWindow() {
        let size = CGSize(width: 100, height: 24)
        let points = MetricSparkline.points([0, 50, 100], in: size, floor: 1, ceiling: nil)
        #expect(points.map(\.x) == [0, 50, 100])
        #expect(points[0].y > points[1].y && points[1].y > points[2].y, "bigger is higher")
        #expect(MetricSparkline.points([5], in: size, floor: 1, ceiling: nil).isEmpty, "one value is no line")
        let flat = MetricSparkline.points([2, 2], in: size, floor: 100, ceiling: nil)
        #expect(flat[0].y > size.height - 3, "a quiet minute stays low under the floor")
        let capped = MetricSparkline.points([0, 100], in: size, floor: 1, ceiling: 200)
        #expect(capped[1].y > size.height / 2, "the ceiling sets the scale")
    }

    @Test func theCardsSayTheirNumbersTheWayTheBoardDoes() {
        #expect(MacFormat.whole(18.6) == "19" && MacFormat.whole(nil) == "–")
        #expect(MacFormat.degrees(35.6) == "36°" && MacFormat.degrees(nil) == nil)
        #expect(MacFormat.bytes(156_000_000_000) == ("156", "GB"))
        #expect(MacFormat.bytes(nil) == ("–", ""))
        let traffic = MacFormat.traffic(Rate(down: 2_800, up: 300))
        #expect(traffic.value == "3.1" && traffic.unit == "KB/s" && traffic.detail == "↓ 2.8  ↑ 0.3")
        #expect(MacFormat.traffic(Rate(down: 12_000_000, up: 400_000)).unit == "MB/s")
        #expect(MacFormat.disk(read: 81_000, written: 1_014_000) == "R 81  W 1014 KB/s")
        #expect(MacFormat.disk(read: nil, written: nil).isEmpty)
        #expect(MacFormat.gigabytes(19.4 * 1_073_741_824) == "19.4 GB")
        #expect(MacFormat.uptime(3 * 86_400 + 4 * 3600 + 120) == "3d 4h")
        #expect(MacFormat.uptime(5 * 3600 + 12 * 60) == "5h 12m" && MacFormat.uptime(30) == "1m")
        #expect(MacFormat.processCPU(1.44) == "1.4%")
    }

    @Test func theSystemsThermalStateIsNormalFairOrThrottling() {
        #expect(ThermalLevel(.nominal) == .normal && ThermalLevel(.fair) == .fair)
        #expect(ThermalLevel(.serious) == .throttling && ThermalLevel(.critical) == .throttling)
        #expect([ThermalLevel.normal, .fair, .throttling].map(\.title) == ["Normal", "Fair", "Throttling"])
    }

    @Test func aReadingsHeatIsInBandsAndItsGaugeFillsOver110Degrees() {
        #expect(Heat(degrees: 69.9) == .cool && Heat(degrees: 70) == .warm && Heat(degrees: 84.9) == .warm)
        #expect(Heat(degrees: 85) == .hot && Heat(degrees: 94.9) == .hot)
        #expect(Heat(degrees: 95) == .critical && Heat(degrees: 140) == .critical)
        #expect(!Heat.warm.tintsReading && Heat.hot.tintsReading && Heat.critical.tintsReading)
        #expect(Heat.gauge(55) == 0.5 && Heat.gauge(200) == 1 && Heat.gauge(-3) == 0)
    }

    @Test func theBatteryLineIsTheTimeLeftOrTheChargingState() {
        var battery = BatteryReport(powerSource: [
            "Current Capacity": 80, "Max Capacity": 100, "Power Source State": "Battery Power", "Time to Empty": 222,
        ])
        #expect(battery.minutesToEmpty == 222 && MacFormat.battery(battery) == "3:42 left")
        battery.minutesToEmpty = nil
        #expect(MacFormat.battery(battery).isEmpty, "still working it out")
        let charging = BatteryReport(powerSource: [
            "Current Capacity": 50, "Max Capacity": 100, "Is Charging": true, "Power Source State": "AC Power",
            "Time to Full Charge": 65, "Time to Empty": 10,
        ])
        #expect(charging.minutesToEmpty == nil && MacFormat.battery(charging) == "1:05 to full")
        let unknown = BatteryReport(powerSource: [
            "Current Capacity": 50, "Max Capacity": 100, "Is Charging": true, "Power Source State": "AC Power",
            "Time to Full Charge": -1,
        ])
        #expect(MacFormat.battery(unknown) == "Charging")
        let held = BatteryReport(powerSource: [
            "Current Capacity": 80, "Max Capacity": 100, "Power Source State": "AC Power",
        ])
        #expect(MacFormat.battery(held) == "Not charging")
    }

    @Test func aGPUTemperatureComesOnlyFromSensorsThatSayGPU() {
        let both = Temperatures(from: [(name: "PMU tdie1", value: 40), (name: "GPU MTR Temp Sensor1", value: 34)])
        #expect(both.gpu == 34 && both.chip == 40)
        #expect(Temperatures(from: [(name: "PMU tdie1", value: 40)]).gpu == nil)
    }
}
