// SPDX-License-Identifier: MIT
// Adapted from OmniMac at 6a56641: Features/Performance (SystemProbes, SystemStats, TopProcesses,
// BatteryReport, Temperature). MIT, Copyright (c) 2026 Sergi (BySergiMM); changed for Topdeck.
// See THIRD_PARTY_NOTICES.md.
import Foundation
import IOKit.ps

// The counting, with no system calls, so it can be tested. `Probes` reads the numbers it works on.

/// One core's cumulative time in each state. Only the difference between two readings means anything.
struct CPUTicks: Equatable, Sendable {
    var user: UInt64
    var system: UInt64
    var idle: UInt64
    var nice: UInt64

    /// How busy the core was since `previous`, 0...100; nil when no time passed, since a 0 would be
    /// as wrong as a 100.
    func usage(since previous: CPUTicks) -> Double? {
        let busy = Double((user &- previous.user) &+ (system &- previous.system) &+ (nice &- previous.nice))
        let total = busy + Double(idle &- previous.idle)
        guard total > 0 else { return nil }
        return min(100, max(0, busy / total * 100))
    }
}

extension CPUTicks {
    /// Per-core load since `previous`; empty unless both readings have the same cores.
    static func loads(from previous: [CPUTicks], to current: [CPUTicks]) -> [Double] {
        guard previous.count == current.count else { return [] }
        return zip(current, previous).map { $0.usage(since: $1) ?? 0 }
    }
}

/// Cores by kind. Apple silicon lists the efficiency cores first; Intel has one kind.
struct CoreLayout: Equatable, Sendable {
    var efficiency: Int
    var performance: Int

    func split(_ loads: [Double]) -> (efficiency: [Double], performance: [Double]) {
        let count = min(efficiency, loads.count)
        return (Array(loads.prefix(count)), Array(loads.dropFirst(count)))
    }
}

/// Memory in bytes, as Activity Monitor adds it up.
struct MemorySample: Equatable, Sendable {
    var active: Double
    var wired: Double
    var compressed: Double
    var total: Double

    var used: Double { active + wired + compressed }
}

/// The kernel's own verdict on memory (`kern.memorystatus_vm_pressure_level`): 1, 2, or 4.
enum MemoryPressure: Equatable, Sendable {
    case normal, warning, critical

    init(level: Int) {
        switch level {
        case 4...: self = .critical
        case 2...: self = .warning
        default: self = .normal
        }
    }

    var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

/// A process at one moment: the CPU time it has used since it started, and the memory it holds.
struct ProcessSample: Equatable, Sendable {
    var pid: Int32
    var cpuSeconds: Double
    var memory: Double
}

/// A process's share, with a name once it's among the top.
struct ProcessUsage: Identifiable, Equatable, Sendable {
    var pid: Int32
    /// Percent of one core; over 100 when it uses several, as in Activity Monitor.
    var cpu: Double
    var memory: Double
    var name = ""

    var id: Int32 { pid }

    /// CPU use of the processes in both readings. A new process has nothing to compare with, and one
    /// whose time went down is a different process on a recycled PID.
    static func cpu(from previous: [ProcessSample], to current: [ProcessSample], seconds: TimeInterval)
        -> [ProcessUsage]
    {
        guard seconds > 0 else { return [] }
        let before = Dictionary(previous.map { ($0.pid, $0.cpuSeconds) }, uniquingKeysWith: { $1 })
        return current.compactMap { sample in
            guard let old = before[sample.pid], sample.cpuSeconds >= old else { return nil }
            return ProcessUsage(pid: sample.pid, cpu: (sample.cpuSeconds - old) / seconds * 100, memory: sample.memory)
        }
    }

    /// The `limit` busiest, most first; under half a percent is not worth a row.
    static func topByCPU(_ usage: [ProcessUsage], limit: Int = 5) -> [ProcessUsage] {
        Array(usage.filter { $0.cpu >= 0.5 }.sorted { $0.cpu > $1.cpu }.prefix(limit))
    }

    static func topByMemory(_ usage: [ProcessUsage], limit: Int = 5) -> [ProcessUsage] {
        Array(usage.sorted { $0.memory > $1.memory }.prefix(limit))
    }
}

/// A rate from two readings of a counter. A counter that went down was reset: no rate, not a huge one.
func perSecond(from previous: UInt64, to current: UInt64, seconds: TimeInterval) -> Double {
    guard seconds > 0, current >= previous else { return 0 }
    return Double(current - previous) / seconds
}

/// The battery's state and health, from the power source and the `AppleSmartBattery` registry entry.
struct BatteryReport: Equatable, Sendable {
    var percent = 0
    var isCharging = false
    var isPluggedIn = false
    var adapterWatts: Int?
    var cycleCount: Int?
    /// Capacity when new and today, in mAh.
    var designCapacity: Int?
    var currentCapacity: Int?
    /// The system's estimates in minutes: to empty while on battery, to full while charging; nil while it works
    /// them out.
    var minutesToEmpty: Int?
    var minutesToFull: Int?

    /// What is left of the capacity when new, in whole percent. macOS's own figure in Settings can
    /// differ by a point or two.
    var health: Int? {
        guard let designCapacity, let currentCapacity, designCapacity > 0 else { return nil }
        return min(100, Int((Double(currentCapacity) / Double(designCapacity) * 100).rounded()))
    }

    init() {}

    /// From `IOPSGetPowerSourceDescription`.
    init(powerSource info: [String: Any]) {
        let current = info[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maximum = info[kIOPSMaxCapacityKey] as? Int ?? 100
        percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : 0
        isCharging = info[kIOPSIsChargingKey] as? Bool ?? false
        isPluggedIn = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        // -1 while the system is still working it out.
        func minutes(_ key: String) -> Int? { (info[key] as? Int).flatMap { $0 > 0 ? $0 : nil } }
        minutesToEmpty = isPluggedIn ? nil : minutes(kIOPSTimeToEmptyKey)
        minutesToFull = isCharging ? minutes(kIOPSTimeToFullChargeKey) : nil
    }

    /// From the registry. Apple silicon keeps the mAh figures in `BatteryData`, Intel loose.
    mutating func apply(registry: [String: Any]) {
        let data = registry["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? { (data[key] as? Int) ?? (registry[key] as? Int) }
        cycleCount = registry["CycleCount"] as? Int
        designCapacity = int("DesignCapacity")
        currentCapacity = int("NominalChargeCapacity") ?? (registry["AppleRawMaxCapacity"] as? Int)
    }
}

/// Chip, SSD, and battery temperatures from the sensors' names and degrees.
struct Temperatures: Equatable, Sendable {
    /// Average of the chip's dies, and the hottest, which is the one that makes the Mac slow down.
    var chip: Double?
    var chipHottest: Double?
    var ssd: Double?
    var battery: Double?
    /// Average of the GPU's sensors, where the Mac names them.
    var gpu: Double?

    init(from raw: [(name: String, value: Double)]) {
        // A sleeping sensor reads 0 and a broken one something absurd.
        let sane = raw.filter { $0.value > 1 && $0.value < 150 }
        // `tcal` is a calibration sensor that reads far higher than the rest.
        let dies = sane.filter {
            let name = $0.name.lowercased()
            return !name.contains("tcal") && (name.contains("tdie") || name.contains("tdev"))
        }.map(\.value)
        chip = dies.isEmpty ? nil : dies.reduce(0, +) / Double(dies.count)
        chipHottest = dies.max()
        ssd = sane.filter { $0.name.lowercased().contains("nand") }.map(\.value).max()
        battery = sane.filter { $0.name.lowercased().contains("battery") }.map(\.value).max()
        let gpus = sane.filter { $0.name.lowercased().contains("gpu") }.map(\.value)
        gpu = gpus.isEmpty ? nil : gpus.reduce(0, +) / Double(gpus.count)
    }

    var isEmpty: Bool { chip == nil && ssd == nil && battery == nil && gpu == nil }
}

/// The system's own verdict on heat (`ProcessInfo.thermalState`): serious and critical both mean it is slowing
/// the Mac down.
enum ThermalLevel: Equatable, Sendable {
    case normal, fair, throttling

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .normal
        case .fair: self = .fair
        case .serious, .critical: self = .throttling
        @unknown default: self = .normal
        }
    }

    var title: String {
        switch self {
        case .normal: "Normal"
        case .fair: "Fair"
        case .throttling: "Throttling"
        }
    }
}

/// How hot a sensor reads, in the bands of the thermal strip's gauges.
enum Heat: Int, Comparable, Sendable {
    case cool, warm, hot, critical

    init(degrees: Double) {
        switch degrees {
        case ..<70: self = .cool
        case ..<85: self = .warm
        case ..<95: self = .hot
        default: self = .critical
        }
    }

    /// How full a gauge is: the reading against 110°.
    static func gauge(_ degrees: Double) -> Double { min(max(degrees / 110, 0), 1) }

    /// From here the reading's own digits take the colour too.
    var tintsReading: Bool { self >= .hot }

    static func < (lhs: Heat, rhs: Heat) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The last values of one reading, oldest first, in a fixed place: a new one replaces the oldest once it is full.
struct RingBuffer: Equatable, Sendable {
    let capacity: Int
    private var storage: [Double] = []
    private var head = 0

    init(capacity: Int = 60) { self.capacity = max(capacity, 1) }

    mutating func append(_ value: Double) {
        if storage.count < capacity {
            storage.append(value)
        } else {
            storage[head] = value
            head = (head + 1) % capacity
        }
    }

    /// The values, oldest first.
    var values: [Double] { head == 0 ? storage : Array(storage[head...] + storage[..<head]) }
}

/// What the Mac page draws as a sparkline: a minute of each reading, a value a second. Kept while the page
/// is on screen and dropped when it isn't.
struct PerformanceHistory: Equatable, Sendable {
    var cpu = RingBuffer()
    var gpu = RingBuffer()
    var network = RingBuffer()
    var disk = RingBuffer()
    var memory = RingBuffer()
    var battery = RingBuffer()

    /// Adds one reading. A rate that isn't known yet (the first reading) is left out, not drawn as zero.
    mutating func record(_ snapshot: PerformanceFeature.Snapshot) {
        if let cpu = snapshot.cpu { self.cpu.append(cpu) }
        if let gpu = snapshot.gpu { self.gpu.append(gpu) }
        if let rate = snapshot.network { network.append(rate.down + rate.up) }
        if let read = snapshot.diskRead, let written = snapshot.diskWritten { disk.append(read + written) }
        if let memory = snapshot.memory, memory.total > 0 { self.memory.append(memory.used / memory.total * 100) }
        if let battery = snapshot.battery { self.battery.append(Double(battery.percent)) }
    }
}

/// The processes' sort order in the Mac page's table.
enum ProcessSort: Equatable, Sendable {
    case name, cpu, memory

    /// The rows for `snapshot`, at most `limit`: the busiest by CPU or memory from the readings' top lists,
    /// or the names in order from both of them.
    func rows(in snapshot: PerformanceFeature.Snapshot, limit: Int) -> [ProcessUsage] {
        let rows: [ProcessUsage]
        switch self {
        case .cpu: rows = snapshot.topCPU
        case .memory: rows = snapshot.topMemory
        case .name:
            var seen: Set<Int32> = []
            rows = (snapshot.topCPU + snapshot.topMemory).filter { seen.insert($0.pid).inserted }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return Array(rows.prefix(max(limit, 0)))
    }
}
