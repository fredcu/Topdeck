// SPDX-License-Identifier: MIT
// Adapted from OmniMac at 6a56641: Features/Performance (SystemProbes, TopProcesses, BatteryReport).
// MIT, Copyright (c) 2026 Sergi (BySergiMM); changed for Topdeck. See THIRD_PARTY_NOTICES.md.
import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration

/// The system readings, one at a time and stateless; `Readings.swift` does the arithmetic. All public
/// API: counters from the kernel and properties from the IORegistry.
enum Probes {
    static func coreTicks() -> [CPUTicks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard
            host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
            let info
        else { return [] }
        defer {
            vm_deallocate(
                task_self_trap(), vm_address_t(bitPattern: info),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size))
        }
        let slots = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { core in
            let base = core * slots
            return CPUTicks(
                user: UInt64(info[base + Int(CPU_STATE_USER)]), system: UInt64(info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt64(info[base + Int(CPU_STATE_IDLE)]), nice: UInt64(info[base + Int(CPU_STATE_NICE)]))
        }
    }

    static func coreLayout() -> CoreLayout {
        // Intel has no performance levels: every core is the same kind.
        guard let efficiency = sysctlInt("hw.perflevel1.logicalcpu"),
            let performance = sysctlInt("hw.perflevel0.logicalcpu")
        else { return CoreLayout(efficiency: 0, performance: ProcessInfo.processInfo.processorCount) }
        return CoreLayout(efficiency: efficiency, performance: performance)
    }

    static func memory() -> MemorySample? {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, let page = sysctlInt("vm.pagesize").map(Double.init) else { return nil }
        return MemorySample(
            active: Double(stats.active_count) * page, wired: Double(stats.wire_count) * page,
            compressed: Double(stats.compressor_page_count) * page,
            total: Double(ProcessInfo.processInfo.physicalMemory))
    }

    static func memoryPressure() -> MemoryPressure {
        MemoryPressure(level: sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1)
    }

    /// The busiest accelerator's utilization, 0...100; nil where the Mac doesn't publish it.
    static func gpuUsage() -> Double? {
        var best: Double?
        for properties in registryProperties(matching: "IOAccelerator") {
            guard let stats = properties["PerformanceStatistics"] as? [String: Any],
                let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
            else { continue }
            best = max(best ?? 0, value)
        }
        return best
    }

    /// Bytes read and written by every storage driver since boot.
    static func diskTotals() -> (read: UInt64, written: UInt64)? {
        let all = registryProperties(matching: "IOBlockStorageDriver").compactMap { $0["Statistics"] as? [String: Any] }
        guard !all.isEmpty else { return nil }
        func sum(_ key: String) -> UInt64 { all.reduce(0) { $0 + ((($1[key]) as? NSNumber)?.uint64Value ?? 0) } }
        return (sum("Bytes (Read)"), sum("Bytes (Write)"))
    }

    /// Free and total space of the startup volume, free as Finder counts it.
    static func diskSpace() -> (free: Int64, total: Int64)? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(filePath: NSHomeDirectory()).resourceValues(forKeys: keys),
            let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity
        else { return nil }
        return (free, Int64(total))
    }

    /// `pti_total_user` is in mach time units, not nanoseconds: 41.67 ns on Apple silicon, 1 on Intel.
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return 1e-9 }
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    /// Every process this user can inspect (others fail `proc_pidinfo`, which is fine).
    static func processes() -> [ProcessSample] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        return pids.prefix(Int(written) / MemoryLayout<pid_t>.size).compactMap { pid in
            var info = proc_taskinfo()
            guard pid > 0, proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
            return ProcessSample(
                pid: pid, cpuSeconds: Double(info.pti_total_user &+ info.pti_total_system) * secondsPerTick,
                memory: Double(info.pti_resident_size))
        }
    }

    /// The app's name where it has one ("Google Chrome"), else the executable's.
    static func name(of pid: pid_t) -> String {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: Int(2 * MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "PID \(pid)" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The internal battery, or nil on a Mac without one.
    static func battery() -> BatteryReport? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                (info[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }
            var report = BatteryReport(powerSource: info)
            if let registry = registryProperties(matching: "AppleSmartBattery").first {
                report.apply(registry: registry)
            }
            if report.isPluggedIn,
                let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
            {
                report.adapterWatts = adapter[kIOPSPowerAdapterWattsKey] as? Int
            }
            return report
        }
        return nil
    }

    /// The one-minute load average.
    static func loadAverage() -> Double? {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : nil
    }

    /// The chip's name without "Apple ": "M5", "M4 Pro", or the Intel part.
    static func chipName() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.hasPrefix("Apple ") ? String(name.dropFirst(6)) : name
    }

    /// What the connection in use is: "Wi-Fi", "Ethernet", or the interface's own name.
    static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Topdeck" as CFString, nil, nil),
            let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
            let name = global["PrimaryInterface"] as? String
        else { return nil }
        let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        guard let interface = all.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == name }) else {
            return name
        }
        let type = SCNetworkInterfaceGetInterfaceType(interface)
        if let type, CFEqual(type, kSCNetworkInterfaceTypeIEEE80211) { return "Wi-Fi" }
        if let type, CFEqual(type, kSCNetworkInterfaceTypeEthernet) { return "Ethernet" }
        return name
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    private static func registryProperties(matching service: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching(service),
            IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var all: [[String: Any]] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                let dictionary = properties?.takeRetainedValue() as? [String: Any]
            else { continue }
            all.append(dictionary)
        }
        return all
    }
}
