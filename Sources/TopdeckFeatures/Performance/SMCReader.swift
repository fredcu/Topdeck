// SPDX-License-Identifier: MIT
import Foundation
import IOKit

/// What the SMC's user client is asked and answers, and how its values are read. No system calls, so it can be
/// tested. `SMCReader` makes the calls.
enum SMC {
    /// The classic `SMCKeyData`, 80 bytes. Swift lays a struct out without the padding C puts after a short
    /// tail, so `KeyInfo` spells its own: it is 12 bytes here as it is in C.
    struct KeyData {
        struct Version {
            var major: UInt8 = 0
            var minor: UInt8 = 0
            var build: UInt8 = 0
            var reserved: UInt8 = 0
            var release: UInt16 = 0
        }

        struct PLimit {
            var version: UInt16 = 0
            var length: UInt16 = 0
            var cpu: UInt32 = 0
            var gpu: UInt32 = 0
            var memory: UInt32 = 0
        }

        struct KeyInfo {
            var dataSize: UInt32 = 0
            var dataType: UInt32 = 0
            var dataAttributes: UInt8 = 0
            var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
        }

        typealias Bytes = (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8
        )

        var key: UInt32 = 0
        var version = Version()
        var limit = PLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    /// The `command` of a request.
    static let readBytes: UInt8 = 5
    static let readKeyInfo: UInt8 = 9

    /// A four character code as the SMC packs it, the first character in the top byte; nil unless it is four
    /// ASCII characters.
    static func code(_ name: String) -> UInt32? {
        let bytes = Array(name.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 < 128 }) else { return nil }
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// A key's value as a number: `flt ` (a Float32 in the machine's byte order) or `sp78` (a signed 8.8 fixed
    /// point, big-endian). Any other type is ignored.
    static func decode(type: UInt32, size: UInt32, bytes: [UInt8]) -> Double? {
        guard bytes.count >= Int(size) else { return nil }
        switch (type, size) {
        case (code("flt ")!, 4):
            let value = Float(
                bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
            return value.isFinite ? Double(value) : nil
        case (code("sp78")!, 2):
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default:
            return nil
        }
    }

    /// The GPU's temperature sensors across Apple silicon generations, as the Stats project (exelban/stats,
    /// MIT) lists them. A Mac answers only to its own, so the list needs no chip detection. M1, M2, M3, M4, M5;
    /// a key two generations share is listed once.
    static let gpuKeys = [
        "Tg05", "Tg0D", "Tg0L", "Tg0T",
        "Tg0f", "Tg0j",
        "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A",
        "Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0d", "Tg0e", "Tg0k",
        "Tg0U", "Tg0X", "Tg0g", "Tg1Y", "Tg1c", "Tg1g",
    ]

    /// The battery's sensor, for a Mac whose registry does not name one.
    static let batteryKey = "TB0T"

    /// The mean of the readings that can be a temperature, 1 to 150°: a sleeping sensor reads 0 and a broken one
    /// something absurd.
    static func average(_ degrees: [Double]) -> Double? {
        let sane = degrees.filter { $0 >= 1 && $0 <= 150 }
        return sane.isEmpty ? nil : sane.reduce(0, +) / Double(sane.count)
    }
}

/// Reads keys from the SMC (`AppleSMC`) through IOKit's `IOConnectCallStructMethod`: private, but needing no
/// root and no entitlement outside the sandbox. Only reads; nothing is ever written. If the service can't be
/// opened `init` returns nil, and the temperatures come from the sensors alone. Touched only from the
/// Performance queue.
final class SMCReader: @unchecked Sendable {
    /// The user client's one method.
    private static let selector: UInt32 = 2

    private let connection: io_connect_t
    /// Each key's size and type, asked once; a size of 0 is a key this Mac does not have.
    private var infos: [UInt32: SMC.KeyData.KeyInfo] = [:]

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        self.connection = connection
    }

    deinit { IOServiceClose(connection) }

    /// A key's number, nil when this Mac has no such key or its type is not one that is read.
    func read(_ name: String) -> Double? {
        guard let key = SMC.code(name) else { return nil }
        var info = infos[key]
        if info == nil {
            var request = SMC.KeyData()
            request.key = key
            request.command = SMC.readKeyInfo
            info = call(request)?.keyInfo ?? SMC.KeyData.KeyInfo()
            infos[key] = info
        }
        guard let info, info.dataSize > 0, info.dataSize <= 32 else { return nil }
        var request = SMC.KeyData()
        request.key = key
        request.keyInfo.dataSize = info.dataSize
        request.command = SMC.readBytes
        guard let answer = call(request) else { return nil }
        let bytes = withUnsafeBytes(of: answer.bytes) { Array($0) }
        return SMC.decode(type: info.dataType, size: info.dataSize, bytes: bytes)
    }

    /// The GPU's temperature, averaged over the sensors this Mac answers for.
    func gpuTemperature() -> Double? { SMC.average(SMC.gpuKeys.compactMap(read)) }

    func batteryTemperature() -> Double? { SMC.average(read(SMC.batteryKey).map { [$0] } ?? []) }

    private func call(_ request: SMC.KeyData) -> SMC.KeyData? {
        var request = request
        var answer = SMC.KeyData()
        var size = MemoryLayout<SMC.KeyData>.stride
        let status = IOConnectCallStructMethod(
            connection, Self.selector, &request, MemoryLayout<SMC.KeyData>.stride, &answer, &size)
        return status == KERN_SUCCESS && answer.result == 0 ? answer : nil
    }
}
