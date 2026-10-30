// SPDX-License-Identifier: MIT
import CoreGraphics
import Foundation
import Testing

@testable import TopdeckFeatures

@MainActor
struct NoteWindowFramesTests {
    private let laptop = NoteScreen(id: "laptop", visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
    private let external = NoteScreen(id: "external", visibleFrame: CGRect(x: 1440, y: 0, width: 2560, height: 1415))

    private func store() throws -> NoteFrameStore {
        try NoteFrameStore(defaults: #require(UserDefaults(suiteName: "NoteWindowFramesTests.\(UUID().uuidString)")))
    }

    @Test func framesAreKeptPerNoteAndDisplay() throws {
        let frames = try store()
        let id = UUID()
        let other = UUID()
        frames.record(CGRect(x: 100, y: 100, width: 240, height: 200), on: "laptop", for: id, connected: ["laptop"])
        let both: Set = ["laptop", "external"]
        frames.record(CGRect(x: 2000, y: 500, width: 300, height: 260), on: "external", for: id, connected: both)
        frames.record(CGRect(x: 10, y: 10, width: 240, height: 200), on: "laptop", for: other, connected: ["laptop"])
        let entry = try #require(frames.entry(for: id))
        #expect(entry.frames["laptop"] == CGRect(x: 100, y: 100, width: 240, height: 200))
        #expect(entry.frames["external"] == CGRect(x: 2000, y: 500, width: 300, height: 260))
        #expect(entry.home == "external", "its home display was there, so the user moved it")
        #expect(frames.entry(for: other)?.frames.count == 1)

        frames.remove(id)
        #expect(frames.entry(for: id) == nil)
        #expect(frames.entry(for: other) != nil)
    }

    @Test func framesSurviveARelaunch() throws {
        let defaults = try #require(UserDefaults(suiteName: "NoteWindowFramesTests.\(UUID().uuidString)"))
        let id = UUID()
        let frame = CGRect(x: 1, y: 2, width: 300, height: 400)
        NoteFrameStore(defaults: defaults).record(frame, on: "laptop", for: id, connected: ["laptop"])
        #expect(NoteFrameStore(defaults: defaults).entry(for: id)?.frames["laptop"]?.width == 300)
    }

    @Test func aWindowGoesBackToItsDisplayWhenItReturns() throws {
        let frames = try store()
        let id = UUID()
        let saved = CGRect(x: 3000, y: 800, width: 300, height: 260)
        frames.record(saved, on: "external", for: id, connected: ["laptop", "external"])

        // Unplugged: onto the laptop at the same size, and the external frame is kept.
        let away = try #require(NoteWindowPlacement.place(frames.entry(for: id), on: [laptop]))
        #expect(away.display == "laptop")
        #expect(away.frame.size == saved.size)
        #expect(laptop.visibleFrame.contains(away.frame))
        #expect(frames.entry(for: id)?.frames["external"] == saved)

        // Dragged about on the laptop meanwhile: remembered there, but home stays the external display.
        let moved = CGRect(x: 50, y: 60, width: 300, height: 260)
        frames.record(moved, on: "laptop", for: id, connected: ["laptop"])
        #expect(NoteWindowPlacement.place(frames.entry(for: id), on: [laptop])?.frame == moved)

        let back = try #require(NoteWindowPlacement.place(frames.entry(for: id), on: [laptop, external]))
        #expect(back.display == "external" && back.frame == saved)
    }

    @Test func newWindowsGoTopRightAndStagger() throws {
        let first = try #require(NoteWindowPlacement.place(nil, on: [laptop, external]))
        #expect(first.display == "laptop")
        #expect(first.frame == CGRect(x: 1440 - 24 - 240, y: 875 - 24 - 200, width: 240, height: 200))
        let second = try #require(NoteWindowPlacement.place(nil, on: [laptop], index: 1))
        #expect(second.frame.origin == CGPoint(x: first.frame.minX - 24, y: first.frame.minY - 24))
        #expect(NoteWindowPlacement.place(nil, on: []) == nil)
    }

    @Test func framesAreKeptOnScreen() {
        let visible = laptop.visibleFrame
        let offScreen = CGRect(x: 1400, y: -50, width: 240, height: 200)
        #expect(NoteWindowPlacement.fit(offScreen, in: visible) == CGRect(x: 1200, y: 0, width: 240, height: 200))
        let huge = CGRect(x: -10, y: 0, width: 2000, height: 2000)
        #expect(NoteWindowPlacement.fit(huge, in: visible) == visible, "too big for the screen: shrunk to fit")
        let inside = CGRect(x: 100, y: 100, width: 240, height: 200)
        #expect(NoteWindowPlacement.fit(inside, in: visible) == inside)
    }
}
