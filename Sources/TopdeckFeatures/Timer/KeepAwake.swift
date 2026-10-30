// SPDX-License-Identifier: MIT
import Foundation
import IOKit.pwr_mgt
import TopdeckCore

/// When keeping awake ends.
public enum AwakeEnd: Equatable, Sendable {
    /// When it's turned off.
    case never
    /// After this many seconds.
    case after(TimeInterval)
    /// The next time the clock reads this hour and minute: later today, or tomorrow once it's past.
    case at(hour: Int, minute: Int)

    /// The moment it ends, starting from `now`; nil when it doesn't.
    public func deadline(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .never: nil
        case .after(let seconds): now.addingTimeInterval(seconds)
        case .at(let hour, let minute):
            // A time that a daylight saving jump skips ends at the first moment after it.
            calendar.nextDate(
                after: now, matching: DateComponents(hour: hour, minute: minute, second: 0), matchingPolicy: .nextTime)
        }
    }
}

/// The power assertions behind keep awake: one keeps the Mac from idle sleep, and a second keeps the
/// display on too when asked. They go through `create` and `release`, so tests can count them.
struct PowerAssertions {
    enum Kind: Sendable { case system, display }

    /// An assertion of this kind, or nil when the Mac refuses one.
    var create: (Kind) -> IOPMAssertionID?
    var release: (IOPMAssertionID) -> Void
    private(set) var held: [Kind: IOPMAssertionID] = [:]

    /// Holds the system assertion, and the display one only while `screenOn`. False when the system
    /// one can't be had; a refused display one just leaves the display free to sleep.
    mutating func hold(screenOn: Bool) -> Bool {
        if held[.system] == nil {
            guard let id = create(.system) else { return false }
            held[.system] = id
        }
        if screenOn, held[.display] == nil {
            held[.display] = create(.display)
        } else if !screenOn, let id = held.removeValue(forKey: .display) {
            release(id)
        }
        return true
    }

    mutating func releaseAll() {
        for id in held.values { release(id) }
        held = [:]
    }

    static var live: PowerAssertions {
        PowerAssertions(
            create: { kind in
                // Named so `pmset -g assertions` says who's keeping the Mac awake.
                let type: String
                let name: String
                switch kind {
                case .system:
                    (type, name) = (kIOPMAssertPreventUserIdleSystemSleep, "Topdeck: Keep Awake, in the Timer tab")
                case .display:
                    (type, name) = (kIOPMAssertPreventUserIdleDisplaySleep, "Topdeck: Keep Awake, screen on")
                }
                var id: IOPMAssertionID = 0
                let status = IOPMAssertionCreateWithName(
                    type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
                guard status == kIOReturnSuccess else {
                    Log.features.error("Couldn't keep the Mac awake: \(status, privacy: .public)")
                    return nil
                }
                return id
            },
            release: { _ = IOPMAssertionRelease($0) })
    }
}
