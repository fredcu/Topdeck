// SPDX-License-Identifier: MIT
// Adapted from MonitorControl (https://github.com/MonitorControl/MonitorControl) at 7cfe645:
// MonitorControl/Support/Arm64DDC.swift. Copyright © 2017 MonitorControl (@JoniVR, @theOneyouseek,
// @waydabber and others). MIT License.
// Symbol loading adapted from MacTools at 9197035: Plugins/DisplayBrightness/Sources/DisplayBrightnessDDC.swift.
// Apache License 2.0; changed for Topdeck. See THIRD_PARTY_NOTICES.md.
import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics
import TopdeckCore

/// A monitor's DDC/CI line. Calls block for tens of milliseconds; make them off the main thread.
protocol DDCChannel: Sendable {
    func read(_ control: DDC.Control) -> DDC.Level?
    func write(_ control: DDC.Control, value: UInt16) -> Bool
}

/// The external displays' DDC/CI lines on Apple silicon: an `IOAVService` for each external
/// `DCPAVServiceProxy` in the I/O Registry. These calls are private, so each is looked up when
/// first used, and if any is missing every monitor shows as unavailable instead of crashing.
/// Intel Macs reach monitors another way, which Topdeck doesn't do, so there it finds none.
enum SystemDDC {
    /// One serial line for every monitor: I²C transactions mustn't interleave.
    private static let queue = DispatchQueue(label: "net.icuai.topdeck.ddc", qos: .userInitiated)

    /// Runs `work` on the DDC queue.
    static func perform<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Whether this Mac has the private calls DDC needs.
    static var isSupported: Bool {
        #if arch(arm64)
            Private.createWithService != nil && Private.readI2C != nil && Private.writeI2C != nil
        #else
            false
        #endif
    }

    /// The channel for each display that has one. Call on the DDC queue.
    static func channels(for displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: any DDCChannel] {
        #if arch(arm64)
            guard isSupported else {
                Log.features.info("DDC: private I²C calls are missing; monitors show as unavailable")
                return [:]
            }
            let services = externalServices()
            let identities = displays.map { (id: $0, identity: identity(of: $0)) }
            return DDC.match(identities, services.map(\.identity)).mapValues { services[$0].channel }
        #else
            return [:]
        #endif
    }

    #if arch(arm64)
        /// Walks the I/O Registry in order: each framebuffer (`AppleCLCD2`, or `IOMobileFramebufferShim`
        /// on older systems) is followed by the `DCPAVServiceProxy` that carries its I²C.
        private static func externalServices() -> [(identity: DDC.ServiceIdentity, channel: any DDCChannel)] {
            let root = IORegistryGetRootEntry(kIOMainPortDefault)
            defer { IOObjectRelease(root) }
            var iterator = io_iterator_t()
            guard
                IORegistryEntryCreateIterator(
                    root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
            else { return [] }
            defer { IOObjectRelease(iterator) }
            var framebuffer = DDC.ServiceIdentity()
            var found: [(identity: DDC.ServiceIdentity, channel: any DDCChannel)] = []
            while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
                defer { IOObjectRelease(entry) }
                let name = registryName(entry)
                if name.contains("AppleCLCD2") || name.contains("IOMobileFramebufferShim") {
                    framebuffer = serviceIdentity(entry)
                } else if name == "DCPAVServiceProxy", property(entry, "Location") as? String == "External",
                    let create = Private.createWithService,
                    let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue()
                {
                    found.append((framebuffer, IOAVChannel(service: service)))
                }
            }
            return found
        }

        private static func registryName(_ entry: io_registry_entry_t) -> String {
            var buffer = [CChar](repeating: 0, count: 128)  // io_name_t
            guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return "" }
            return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        private static func serviceIdentity(_ entry: io_registry_entry_t) -> DDC.ServiceIdentity {
            var identity = DDC.ServiceIdentity()
            identity.edidUUID = property(entry, "EDID UUID") as? String ?? ""
            identity.location = IORegistryEntryCopyPath(entry, kIOServicePlane)?.takeRetainedValue() as String? ?? ""
            let attributes = property(entry, "DisplayAttributes") as? [String: Any]
            let product = attributes?["ProductAttributes"] as? [String: Any]
            identity.productName = product?["ProductName"] as? String ?? ""
            identity.serial = (product?["SerialNumber"] as? NSNumber)?.int64Value ?? 0
            return identity
        }
    #endif

    /// What macOS says about a display, from CoreDisplay when it can, else from Core Graphics.
    static func identity(of display: CGDirectDisplayID) -> DDC.DisplayIdentity {
        guard let info = Private.displayInfo?(display)?.takeRetainedValue() as? [String: Any] else {
            return DDC.DisplayIdentity(
                vendor: Int64(CGDisplayVendorNumber(display)), product: Int64(CGDisplayModelNumber(display)),
                serial: Int64(CGDisplaySerialNumber(display)))
        }
        func number(_ key: String) -> Int64? { (info[key] as? NSNumber)?.int64Value }
        let names = info[kDisplayProductName] as? [String: String]
        return DDC.DisplayIdentity(
            vendor: number(kDisplayVendorID), product: number(kDisplayProductID), serial: number(kDisplaySerialNumber),
            week: number(kDisplayWeekOfManufacture), year: number(kDisplayYearOfManufacture),
            horizontalSize: number(kDisplayHorizontalImageSize), verticalSize: number(kDisplayVerticalImageSize),
            location: info[kIODisplayLocationKey] as? String, name: names?["en_US"] ?? names?.values.first)
    }

    /// The private calls, each nil if this macOS doesn't have it.
    fileprivate enum Private {
        typealias CreateWithService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
        /// Reads or writes I²C: the service, the address, the sub-address, the bytes, their count.
        typealias I2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> IOReturn
        typealias DisplayInfo = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

        static let createWithService: CreateWithService? = symbol("IOAVServiceCreateWithService")
        static let readI2C: I2C? = symbol("IOAVServiceReadI2C")
        static let writeI2C: I2C? = symbol("IOAVServiceWriteI2C")
        static let displayInfo: DisplayInfo? = symbol(
            "CoreDisplay_DisplayCreateInfoDictionary",
            in: "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay")

        private static func symbol<T>(_ name: String, in framework: String? = nil) -> T? {
            if let framework, let handle = dlopen(framework, RTLD_LAZY), let pointer = dlsym(handle, name) {
                return unsafeBitCast(pointer, to: T.self)
            }
            let loaded = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT: every loaded image
            return dlsym(loaded, name).map { unsafeBitCast($0, to: T.self) }
        }
    }
}

/// One monitor's `IOAVService`. Used only on the DDC queue.
private final class IOAVChannel: DDCChannel, @unchecked Sendable {
    private let service: CFTypeRef

    init(service: CFTypeRef) {
        self.service = service
    }

    // MonitorControl's timing: each request written twice, 10 ms apart, the reply read 50 ms later,
    // and up to five tries 20 ms apart.
    private static let attempts = 5
    private static let writes = 2

    func read(_ control: DDC.Control) -> DDC.Level? {
        var request = DDC.readRequest(control)
        for _ in 0..<Self.attempts {
            if send(&request) {
                usleep(50_000)
                var reply = [UInt8](repeating: 0, count: DDC.replyLength)
                if transfer(SystemDDC.Private.readI2C, dataAddress: 0, &reply),
                    let level = DDC.parseReply(reply, for: control)
                {
                    return level
                }
            }
            usleep(20_000)
        }
        return nil
    }

    func write(_ control: DDC.Control, value: UInt16) -> Bool {
        var request = DDC.writeRequest(control, value: value)
        for _ in 0..<Self.attempts {
            if send(&request) { return true }
            usleep(20_000)
        }
        return false
    }

    private func send(_ request: inout [UInt8]) -> Bool {
        var sent = false
        for _ in 0..<Self.writes {
            usleep(10_000)
            sent = transfer(SystemDDC.Private.writeI2C, dataAddress: UInt32(DDC.dataAddress), &request) || sent
        }
        return sent
    }

    private func transfer(_ call: SystemDDC.Private.I2C?, dataAddress: UInt32, _ bytes: inout [UInt8]) -> Bool {
        guard let call else { return false }
        let service = service
        let status = bytes.withUnsafeMutableBytes { buffer in
            call(service, UInt32(DDC.address), dataAddress, buffer.baseAddress, UInt32(buffer.count))
        }
        return status == kIOReturnSuccess
    }
}
