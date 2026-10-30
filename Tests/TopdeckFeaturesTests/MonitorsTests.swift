// SPDX-License-Identifier: MIT
import CoreGraphics
import Foundation
import Testing
import TopdeckCore

@testable import TopdeckFeatures

struct DDCMessageTests {
    @Test func readRequestsAskForOneControl() {
        // 0x82: a two-byte message; 0x01: Get VCP Feature; checksum seeded with the monitor's 0x6E.
        #expect(DDC.readRequest(.brightness) == [0x82, 0x01, 0x10, 0xFD])
        #expect(DDC.readRequest(.volume) == [0x82, 0x01, 0x62, 0x6E ^ 0x82 ^ 0x01 ^ 0x62])
    }

    @Test func writeRequestsCarryTheValueHighByteFirst() {
        // 0x84: four bytes; 0x03: Set VCP Feature; checksum seeded with 0x6E ^ 0x51.
        #expect(DDC.writeRequest(.brightness, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
        #expect(DDC.writeRequest(.volume, value: 75) == [0x84, 0x03, 0x62, 0x00, 0x4B, 0x91])
        let wide = DDC.writeRequest(.brightness, value: 0x1234)
        #expect(wide[3...4] == [0x12, 0x34])
        #expect(wide.last == [0x6E, 0x51, 0x84, 0x03, 0x10, 0x12, 0x34].reduce(0, ^))
    }

    /// A Get VCP Feature reply from the monitor, with a correct checksum unless one is given.
    private func reply(
        control: UInt8 = 0x10, result: UInt8 = 0, maximum: UInt16 = 100, current: UInt16 = 50, checksum: UInt8? = nil
    ) -> [UInt8] {
        let body: [UInt8] = [
            0x6E, 0x88, 0x02, result, control, 0x00,
            UInt8(maximum >> 8), UInt8(maximum & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF),
        ]
        return body + [checksum ?? body.reduce(0x50, ^)]
    }

    @Test func aReplyGivesTheValueAndItsRange() {
        #expect(reply().last == 0xF2)
        #expect(DDC.parseReply(reply(), for: .brightness) == DDC.Level(current: 50, maximum: 100))
        #expect(
            DDC.parseReply(reply(control: 0x62, maximum: 0x0100, current: 0x0080), for: .volume)
                == DDC.Level(current: 128, maximum: 256))
    }

    @Test func aBadReplyGivesNothing() {
        #expect(DDC.parseReply(reply(checksum: 0x00), for: .brightness) == nil, "garbled")
        #expect(DDC.parseReply(reply(result: 1), for: .brightness) == nil, "unsupported control")
        #expect(DDC.parseReply(reply(control: 0x62), for: .brightness) == nil, "another control's reply")
        #expect(DDC.parseReply(reply(maximum: 0, current: 0), for: .brightness) == nil, "no range")
        #expect(DDC.parseReply(Array(reply().prefix(8)), for: .brightness) == nil, "cut short")
        #expect(DDC.parseReply([UInt8](repeating: 0, count: 11), for: .brightness) == nil, "silence")
        var wrongOpcode = reply()
        wrongOpcode[2] = 0x07
        wrongOpcode[10] = wrongOpcode.prefix(10).reduce(0x50, ^)
        #expect(DDC.parseReply(wrongOpcode, for: .brightness) == nil, "not a VCP reply")
    }

    @Test func aValuePastTheMaximumReadsAsFull() {
        let level = DDC.parseReply(reply(maximum: 100, current: 140), for: .brightness)
        #expect(level == DDC.Level(current: 100, maximum: 100))
        #expect(level?.fraction == 1)
    }
}

struct DDCValueTests {
    @Test func levelsReadAsFractions() {
        #expect(DDC.Level(current: 50, maximum: 100).fraction == 0.5)
        #expect(DDC.Level(current: 0, maximum: 100).fraction == 0)
        #expect(DDC.Level(current: 255, maximum: 255).fraction == 1)
        #expect(DDC.Level(current: 3, maximum: 0).fraction == 0, "no range")
    }

    @Test func fractionsMapToTheNearestValueTheMonitorCounts() {
        let percent = DDC.Level(current: 0, maximum: 100)
        #expect(percent.value(for: 0.5) == 50)
        #expect(percent.value(for: 0.333) == 33)
        #expect(percent.value(for: 0.336) == 34)
        let coarse = DDC.Level(current: 0, maximum: 10)
        #expect(coarse.value(for: 0.44) == 4)
        #expect(coarse.value(for: 0.46) == 5)
        let fine = DDC.Level(current: 0, maximum: 0xFFFF)
        #expect(fine.value(for: 1) == 0xFFFF)
    }

    @Test func fractionsOutOfRangeAreClamped() {
        let level = DDC.Level(current: 0, maximum: 100)
        #expect(level.value(for: -0.2) == 0)
        #expect(level.value(for: 1.7) == 100)
        #expect(level.value(for: .nan) == 0)
        #expect(level.value(for: .infinity) == 0)
    }

    @Test func everyValueSurvivesARoundTrip() {
        for maximum: UInt16 in [10, 37, 100, 255] {
            for current in 0...maximum {
                let level = DDC.Level(current: current, maximum: maximum)
                #expect(level.value(for: level.fraction) == current, "\(current)/\(maximum)")
            }
        }
    }
}

struct DDCMatchTests {
    // A Dell monitor: vendor 0x10AC, product 0xA04B (low byte first in the UUID), made in week 46 of
    // 2020, 60 × 34 cm.
    private let uuid = "10AC4BA0-0000-0000-2E1E-0104B53C2278"
    private let dell = DDC.DisplayIdentity(
        vendor: 0x10AC, product: 0xA04B, serial: 12345, week: 46, year: 2020, horizontalSize: 600, verticalSize: 340,
        location: "IOService:/AppleARMPE/dispext0", name: "DELL U2720Q")

    @Test func eachPartOfTheEDIDUUIDThatAgreesCounts() {
        #expect(DDC.matchScore(dell, DDC.ServiceIdentity(edidUUID: uuid)) == 4)
        #expect(DDC.matchScore(dell, DDC.ServiceIdentity(edidUUID: uuid.lowercased())) == 4)
        #expect(DDC.matchScore(dell, DDC.ServiceIdentity(edidUUID: "10AC0000-0000-0000-0000-000000000000")) == 1)
        #expect(DDC.matchScore(dell, DDC.ServiceIdentity(edidUUID: "")) == 0)
        #expect(DDC.matchScore(dell, DDC.ServiceIdentity(edidUUID: "10AC")) == 1, "short UUIDs don't trap")
    }

    @Test func theSameFramebufferNameAndSerialCount() {
        let service = DDC.ServiceIdentity(
            edidUUID: uuid, location: "IOService:/AppleARMPE/dispext0", productName: "Dell U2720Q", serial: 12345)
        #expect(DDC.matchScore(dell, service) == 4 + 10 + 1 + 1)
        #expect(DDC.matchScore(DDC.DisplayIdentity(), service) == 0)
    }

    @Test func identicalMonitorsAreToldApartByTheirFramebuffers() {
        var left = dell
        left.location = "IOService:/AppleARMPE/dispext1"
        let services = [
            DDC.ServiceIdentity(edidUUID: uuid, location: "IOService:/AppleARMPE/dispext1"),
            DDC.ServiceIdentity(edidUUID: uuid, location: "IOService:/AppleARMPE/dispext0"),
        ]
        let matches = DDC.match([(id: 1, identity: dell), (id: 2, identity: left)], services)
        #expect(matches == [1: 1, 2: 0])
    }

    @Test func eachServiceIsUsedOnceAndStrangersStayUnmatched() {
        let services = [DDC.ServiceIdentity(edidUUID: uuid)]
        let stranger = DDC.DisplayIdentity(vendor: 0x4C2D, product: 0x0F00)
        let displays = [(id: 7, identity: stranger), (id: 8, identity: dell), (id: 9, identity: dell)]
        let matches = DDC.match(displays, services)
        #expect(matches == [8: 0], "the first of two equal matches wins; nobody shares")
    }
}

struct LatestValueGateTests {
    @Test func onlyTheNewestValueWaitsBehindASend() {
        var gate = LatestValueGate<Int>()
        #expect(gate.submit(10) == 10)
        #expect(gate.submit(20) == nil)
        #expect(gate.submit(30) == nil)
        #expect(gate.finished() == 30, "20 was overtaken")
        #expect(gate.finished() == nil)
        #expect(gate.sending == nil)
        #expect(gate.submit(40) == 40, "idle again: sends at once")
    }

    @Test func aValueAlreadySentIsntSentAgain() {
        var gate = LatestValueGate<Int>()
        #expect(gate.submit(10) == 10)
        #expect(gate.submit(10) == nil)
        #expect(gate.finished() == nil)
    }
}

/// A monitor that answers with set values and records what it's sent.
final class FakeMonitor: DDCChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DDC.Control: DDC.Level]
    private var sent: [(DDC.Control, UInt16)] = []

    init(_ values: [DDC.Control: DDC.Level]) {
        self.values = values
    }

    var writes: [(DDC.Control, UInt16)] { lock.withLock { sent } }

    func read(_ control: DDC.Control) -> DDC.Level? { lock.withLock { values[control] } }

    func write(_ control: DDC.Control, value: UInt16) -> Bool {
        lock.withLock {
            guard values[control] != nil else { return false }
            values[control]?.current = value
            sent.append((control, value))
            return true
        }
    }
}

@MainActor
struct MonitorsFeatureTests {
    private let speakers = FakeMonitor([
        .brightness: DDC.Level(current: 30, maximum: 100), .volume: DDC.Level(current: 10, maximum: 40),
    ])
    private let noSpeakers = FakeMonitor([.brightness: DDC.Level(current: 255, maximum: 255)])
    private final class Slept: @unchecked Sendable { var count = 0 }
    private let slept = Slept()

    private func feature(displays: [(id: CGDirectDisplayID, name: String)]) -> MonitorsFeature {
        let channels: [CGDirectDisplayID: any DDCChannel] = [1: speakers, 2: noSpeakers]
        let slept = slept
        return MonitorsFeature(
            backend: .init(
                displays: { displays },
                channels: { ids in channels.filter { ids.contains($0.key) } },
                perform: { $0() },
                send: { $0() },
                sleepDisplays: {
                    await MainActor.run { slept.count += 1 }
                    return true
                }))
    }

    @Test func eachMonitorShowsWhatItAnswers() async {
        let monitors = feature(displays: [(1, "Studio"), (2, "Office"), (3, "Projector")])
        monitors.phase = .foreground
        #expect(await eventually { monitors.monitors.allSatisfy { $0.status != .checking } })
        let byID = Dictionary(uniqueKeysWithValues: monitors.monitors.map { ($0.id, $0) })
        #expect(byID[1]?.brightness == 0.3)
        #expect(byID[1]?.volume == 0.25)
        #expect(byID[1]?.status == .ready)
        #expect(byID[2]?.brightness == 1)
        #expect(byID[2]?.volume == nil, "no speakers: no volume")
        #expect(byID[3]?.status == .unavailable, "doesn't answer DDC")
        #expect(monitors.monitors.map(\.name) == ["Studio", "Office", "Projector"])
    }

    @Test func slidingSetsTheMonitorInItsOwnUnits() async {
        let monitors = feature(displays: [(1, "Studio")])
        monitors.phase = .foreground
        #expect(await eventually { monitors.monitors.first?.status == .ready })
        monitors.set(.volume, of: 1, to: 0.5)
        #expect(monitors.monitors.first?.volume == 0.5, "the slider moves at once")
        #expect(await eventually { !speakers.writes.isEmpty })
        #expect(speakers.writes.last?.0 == .volume)
        #expect(speakers.writes.last?.1 == 20, "half of 40")
        monitors.set(.brightness, of: 1, to: 2)
        #expect(await eventually { speakers.writes.last?.1 == 100 })
        #expect(monitors.monitors.first?.brightness == 1)
    }

    @Test func aControlTheMonitorLacksCantBeSet() async {
        let monitors = feature(displays: [(2, "Office"), (3, "Projector")])
        monitors.phase = .foreground
        #expect(await eventually { monitors.monitors.allSatisfy { $0.status != .checking } })
        monitors.set(.volume, of: 2, to: 0.5)
        monitors.set(.brightness, of: 3, to: 0.5)
        #expect(monitors.monitors.map(\.volume) == [nil, nil])
        #expect(monitors.monitors.last?.brightness == nil)
        #expect(noSpeakers.writes.isEmpty)
    }

    @Test func noExternalMonitorsIsSaidOnceLooked() async {
        let monitors = feature(displays: [])
        #expect(!monitors.hasLooked)
        monitors.phase = .foreground
        #expect(await eventually { monitors.hasLooked })
        #expect(monitors.monitors.isEmpty)
    }

    @Test func stoppingLetsGoOfEveryMonitor() async {
        let monitors = feature(displays: [(1, "Studio")])
        monitors.phase = .foreground
        #expect(await eventually { monitors.monitors.first?.status == .ready })
        monitors.phase = .background
        #expect(monitors.monitors.count == 1, "kept while off screen")
        monitors.phase = .stopped
        #expect(monitors.monitors.isEmpty)
        #expect(!monitors.hasLooked)
        monitors.set(.brightness, of: 1, to: 0.9)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(speakers.writes.isEmpty)
    }

    @Test func sleepingAsksOnce() async {
        let monitors = feature(displays: [])
        monitors.sleepDisplays()
        #expect(await eventually { slept.count == 1 })
    }
}
