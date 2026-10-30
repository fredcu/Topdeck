// SPDX-License-Identifier: MIT
// Adapted from OmniMac at 6a56641: Features/Performance/Temperature.swift. MIT, Copyright (c) 2026
// Sergi (BySergiMM); changed for Topdeck. See THIRD_PARTY_NOTICES.md.
import Foundation

/// Degrees from Apple's temperature sensors, through `IOHIDEventSystemClient`, which is private API.
/// Its symbols are looked up with `dlsym` rather than linked: if a macOS version removes one, `init`
/// returns nil and the tab shows no temperature. Reads only; nothing is written and no permission is
/// needed. The client lives as long as the object, which the Performance tab holds only while on screen.
final class TemperatureSensors: @unchecked Sendable {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias EventFloat = @convention(c) (AnyObject, Int32) -> Double

    /// The temperature event type and the field that holds its value.
    private static let temperatureEvent: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16
    /// Apple's temperature sensors: usage page 0xff00, usage 5.
    private static let matching: [String: Int] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]

    private let client: AnyObject
    private let copyServices: CopyServices
    private let copyProperty: CopyProperty
    private let copyEvent: CopyEvent
    private let eventFloat: EventFloat

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
            let create = dlsym(handle, "IOHIDEventSystemClientCreate"),
            let setMatching = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
            let services = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
            let property = dlsym(handle, "IOHIDServiceClientCopyProperty"),
            let event = dlsym(handle, "IOHIDServiceClientCopyEvent"),
            let float = dlsym(handle, "IOHIDEventGetFloatValue"),
            let created = unsafeBitCast(create, to: CreateClient.self)(kCFAllocatorDefault)
        else { return nil }
        client = created.takeRetainedValue()
        unsafeBitCast(setMatching, to: SetMatching.self)(client, Self.matching as CFDictionary)
        copyServices = unsafeBitCast(services, to: CopyServices.self)
        copyProperty = unsafeBitCast(property, to: CopyProperty.self)
        copyEvent = unsafeBitCast(event, to: CopyEvent.self)
        eventFloat = unsafeBitCast(float, to: EventFloat.self)
    }

    /// Every sensor's name and degrees; empty when this macOS answers with nothing.
    func read() -> [(name: String, value: Double)] {
        guard let services = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return [] }
        return services.compactMap { service in
            guard let event = copyEvent(service, Self.temperatureEvent, 0, 0) else { return nil }
            let value = eventFloat(event.takeRetainedValue(), Self.temperatureField)
            guard value > 0 else { return nil }
            return (copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? "?", value)
        }
    }
}
