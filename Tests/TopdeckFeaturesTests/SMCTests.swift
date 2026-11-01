// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import TopdeckFeatures

/// The SMC's request and its values, as pure logic: nothing here opens the SMC.
struct SMCTests {
    @Test func theRequestIsTheEightyBytesTheSMCExpects() {
        #expect(MemoryLayout<SMC.KeyData>.size == 80 && MemoryLayout<SMC.KeyData>.stride == 80)
        #expect(MemoryLayout<SMC.KeyData.KeyInfo>.stride == 12)
        #expect(MemoryLayout<SMC.KeyData>.offset(of: \.key) == 0)
        #expect(MemoryLayout<SMC.KeyData>.offset(of: \.version) == 4)
        #expect(MemoryLayout<SMC.KeyData>.offset(of: \.limit) == 12)
        #expect(MemoryLayout<SMC.KeyData>.offset(of: \.keyInfo) == 28)
        #expect(MemoryLayout<SMC.KeyData>.offset(of: \.result) == 40)
        #expect(MemoryLayout<SMC.KeyData>.offset(of: \.command) == 42)
        #expect(MemoryLayout<SMC.KeyData>.offset(of: \.data32) == 44)
        #expect(MemoryLayout<SMC.KeyData>.offset(of: \.bytes) == 48)
    }

    @Test func aFourCharacterCodeIsPackedFirstCharacterHighest() {
        #expect(SMC.code("flt ") == 0x666C_7420)
        #expect(SMC.code("Tg0U") == 0x5467_3055)
        #expect(SMC.code("Tg0") == nil && SMC.code("Tg0UU") == nil && SMC.code("Tg0é") == nil)
    }

    @Test func aFloatIsReadInTheMachinesByteOrder() {
        let float = SMC.code("flt ")!
        #expect(SMC.decode(type: float, size: 4, bytes: [0x00, 0x00, 0x0E, 0x42]) == 35.5)
        #expect(SMC.decode(type: float, size: 4, bytes: [0x00, 0x00, 0xC0, 0x7F]) == nil, "not a number")
        #expect(SMC.decode(type: float, size: 4, bytes: [0x00, 0x00]) == nil, "short")
        #expect(SMC.decode(type: float, size: 2, bytes: [0x00, 0x00]) == nil, "not a Float32")
    }

    @Test func aFixedPointValueIsBigEndianInEightBitFractions() {
        let fixed = SMC.code("sp78")!
        #expect(SMC.decode(type: fixed, size: 2, bytes: [0x23, 0x80]) == 35.5)
        #expect(SMC.decode(type: fixed, size: 2, bytes: [0xFF, 0x00]) == -1)
    }

    @Test func otherTypesAreIgnored() {
        #expect(SMC.decode(type: SMC.code("ui8 ")!, size: 1, bytes: [7]) == nil)
        #expect(SMC.decode(type: SMC.code("ch8*")!, size: 4, bytes: [1, 2, 3, 4]) == nil)
    }

    @Test func onlyReadingsThatCanBeATemperatureAreAveraged() {
        #expect(SMC.average([34, 36]) == 35)
        #expect(SMC.average([34, 0, 36, 900, -5]) == 35, "a sleeping or broken sensor is left out")
        #expect(SMC.average([0.5, 151]) == nil && SMC.average([]) == nil)
        #expect(SMC.average([1, 150]) == 75.5)
    }

    @Test func theGPUKeysAreFourCharactersEachAndListedOnce() {
        #expect(Set(SMC.gpuKeys).count == SMC.gpuKeys.count)
        #expect(SMC.gpuKeys.allSatisfy { SMC.code($0) != nil } && SMC.code(SMC.batteryKey) != nil)
        // The keys read here on an M5, and one from each earlier generation.
        for key in ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g", "Tg05", "Tf14", "Tg0G"] {
            #expect(SMC.gpuKeys.contains(key))
        }
    }

    @Test func theSMCsGPUWinsAndItsBatteryOnlyStandsIn() {
        var named = Temperatures(from: [
            (name: "GPU MTR Temp Sensor", value: 50), (name: "gas gauge battery", value: 30),
        ])
        named.apply(smcGPU: 35, smcBattery: 33)
        #expect(named.gpu == 35 && named.battery == 30)
        var bare = Temperatures(from: [(name: "PMU tdie1", value: 40)])
        #expect(bare.gpu == nil && bare.battery == nil)
        bare.apply(smcGPU: nil, smcBattery: 33)
        #expect(bare.gpu == nil && bare.battery == 33)
        bare.apply(smcGPU: 36, smcBattery: nil)
        #expect(bare.gpu == 36 && bare.battery == 33)
    }
}
