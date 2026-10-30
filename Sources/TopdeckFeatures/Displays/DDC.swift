// SPDX-License-Identifier: MIT
// Adapted from MonitorControl (https://github.com/MonitorControl/MonitorControl) at 7cfe645:
// MonitorControl/Support/Arm64DDC.swift. Copyright © 2017 MonitorControl (@JoniVR, @theOneyouseek,
// @waydabber and others). MIT License.
// Reply checks adapted from MacTools at 9197035: Plugins/DisplayBrightness/Sources/DisplayBrightnessDDC.swift.
// Apache License 2.0; changed for Topdeck. See THIRD_PARTY_NOTICES.md.
import Foundation

/// DDC/CI, the I²C protocol a monitor's own buttons speak: the messages Topdeck sends to read and set
/// a control, and what a reply means. No I/O here; `DDCChannel` carries the bytes.
enum DDC {
    /// The VCP codes Topdeck uses.
    enum Control: UInt8, CaseIterable, Sendable {
        case brightness = 0x10
        case volume = 0x62
    }

    /// A control's value as the monitor counts it: `current` out of `maximum`, which the monitor picks.
    struct Level: Equatable, Sendable {
        var current: UInt16
        var maximum: UInt16

        /// 0...1, the way sliders show it.
        var fraction: Double { maximum == 0 ? 0 : min(Double(current) / Double(maximum), 1) }

        /// The monitor's nearest value to `fraction`.
        func value(for fraction: Double) -> UInt16 {
            let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
            return UInt16((clamped * Double(maximum)).rounded())
        }
    }

    /// The monitor's 7-bit I²C address, and the sub-address its DDC/CI host writes to.
    static let address: UInt8 = 0x37
    static let dataAddress: UInt8 = 0x51

    private static let getOpcode: UInt8 = 0x01
    private static let setOpcode: UInt8 = 0x03
    private static let replyOpcode: UInt8 = 0x02
    /// Seeds a reply's checksum: the virtual address a monitor answers from.
    private static let replySeed: UInt8 = 0x50
    /// A Get VCP Feature reply's length: address, length, opcode, result, code, type, maximum,
    /// current, checksum.
    static let replyLength = 11

    /// Asks for a control's value; the reply follows in a separate read.
    static func readRequest(_ control: Control) -> [UInt8] {
        packet([getOpcode, control.rawValue])
    }

    /// Sets a control. Monitors send no reply.
    static func writeRequest(_ control: Control, value: UInt16) -> [UInt8] {
        packet([setOpcode, control.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// The length byte, the message, and a checksum. The checksum is seeded with the monitor's
    /// 8-bit address, and for a write the sub-address too, as MonitorControl sends it: monitors
    /// answer this form on Apple silicon.
    private static func packet(_ message: [UInt8]) -> [UInt8] {
        var seed = address << 1
        if message.count > 2 { seed ^= dataAddress }
        let bytes = [0x80 | UInt8(message.count)] + message
        return bytes + [bytes.reduce(seed, ^)]
    }

    /// The value in a reply to `readRequest(control)`, or nil when the reply is garbled, says the
    /// monitor doesn't support the control, answers for another control, or has no range.
    static func parseReply(_ reply: [UInt8], for control: Control) -> Level? {
        guard reply.count >= replyLength else { return nil }
        let body = reply.prefix(replyLength - 1)
        guard body.reduce(replySeed, ^) == reply[replyLength - 1],
            reply[2] == replyOpcode,
            reply[3] == 0,  // result code: supported
            reply[4] == control.rawValue
        else { return nil }
        let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        guard maximum > 0 else { return nil }
        return Level(current: min(current, maximum), maximum: maximum)
    }
}

// MARK: - Which I²C service drives which display

extension DDC {
    /// What macOS says about a display, from CoreDisplay's info dictionary, or, without it, from
    /// Core Graphics' vendor, model, and serial.
    struct DisplayIdentity: Equatable, Sendable {
        var vendor: Int64?
        var product: Int64?
        var serial: Int64?
        var week: Int64?
        var year: Int64?
        var horizontalSize: Int64?
        var verticalSize: Int64?
        /// Its framebuffer's I/O Registry path.
        var location: String?
        var name: String?
    }

    /// What the I/O Registry says about the framebuffer an external I²C service belongs to.
    struct ServiceIdentity: Equatable, Sendable {
        var edidUUID = ""
        var location = ""
        var productName = ""
        var serial: Int64 = 0
    }

    /// How sure a match is: a point for each part of the EDID UUID that agrees, a point each for
    /// the name and serial, and ten for the same framebuffer.
    static func matchScore(_ display: DisplayIdentity, _ service: ServiceIdentity) -> Int {
        var score = 0
        let uuid = service.edidUUID.uppercased()
        for (key, offset) in edidKeys(display) where key != "0000" {
            let end = offset + 4
            guard uuid.count >= end else { continue }
            if String(uuid.prefix(end).suffix(4)) == key { score += 1 }
        }
        if let location = display.location, !service.location.isEmpty, location == service.location { score += 10 }
        if let name = display.name, !service.productName.isEmpty,
            name.lowercased() == service.productName.lowercased()
        {
            score += 1
        }
        if service.serial != 0, display.serial == service.serial { score += 1 }
        return score
    }

    /// Where an EDID UUID spells out the vendor, the product (low byte first), the week and year
    /// made, and the image size in centimetres.
    private static func edidKeys(_ display: DisplayIdentity) -> [(String, Int)] {
        func hex(_ value: Int64, bytes: Int) -> String {
            let limit = bytes == 2 ? Int64(UInt16.max) : Int64(UInt8.max)
            return String(format: bytes == 2 ? "%04X" : "%02X", min(max(value, 0), limit))
        }
        var keys: [(String, Int)] = []
        if let vendor = display.vendor { keys.append((hex(vendor, bytes: 2), 0)) }
        if let product = display.product {
            let value = min(max(product, 0), Int64(UInt16.max))
            keys.append((hex(value & 0xFF, bytes: 1) + hex(value >> 8, bytes: 1), 4))
        }
        if let week = display.week, let year = display.year {
            keys.append((hex(week, bytes: 1) + hex(year - 1990, bytes: 1), 19))
        }
        if let horizontal = display.horizontalSize, let vertical = display.verticalSize {
            keys.append((hex(horizontal / 10, bytes: 1) + hex(vertical / 10, bytes: 1), 30))
        }
        return keys
    }

    /// Pairs displays with services, surest match first; each is used once, and a pair with
    /// nothing in common isn't made. Returns each matched display's service index.
    static func match<ID: Hashable>(_ displays: [(id: ID, identity: DisplayIdentity)], _ services: [ServiceIdentity])
        -> [ID: Int]
    {
        var candidates: [(id: ID, service: Int, score: Int, order: Int)] = []
        for display in displays {
            for (index, service) in services.enumerated() {
                let score = matchScore(display.identity, service)
                if score > 0 { candidates.append((display.id, index, score, candidates.count)) }
            }
        }
        candidates.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        var matches: [ID: Int] = [:]
        var taken: Set<Int> = []
        for candidate in candidates where matches[candidate.id] == nil && !taken.contains(candidate.service) {
            matches[candidate.id] = candidate.service
            taken.insert(candidate.service)
        }
        return matches
    }
}

/// Sends only the newest value while one is on its way: a slider dragged across a monitor's range
/// makes a few writes, not one for every step. Each I²C write takes tens of milliseconds.
struct LatestValueGate<Value: Equatable> {
    private(set) var sending: Value?
    private var waiting: Value?

    /// The value to send now, or nil when a send is in flight; then it goes next.
    mutating func submit(_ value: Value) -> Value? {
        guard sending == nil else {
            waiting = value
            return nil
        }
        sending = value
        return value
    }

    /// Call when a send finishes: the value to send next, if a newer one came in meanwhile.
    mutating func finished() -> Value? {
        let next = waiting.flatMap { $0 == sending ? nil : $0 }
        waiting = nil
        sending = next
        return next
    }
}
