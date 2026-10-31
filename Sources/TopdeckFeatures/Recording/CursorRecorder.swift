// SPDX-License-Identifier: MIT
// Adapted from Snapzy (https://github.com/duongductrong/Snapzy) at 77d3d3f: Services/Capture/RecordingMouseTracker.swift.
// Copyright (c) 2026, Trong Duong Duc. BSD 3-Clause License; see THIRD_PARTY_NOTICES.md.
import AppKit
import Foundation

/// Samples where the pointer is, thirty times a second while a recording runs, relative to the recorded area.
/// Held time is left out, so a sample's time is a time in the video.
@MainActor
final class CursorRecorder {
    private var track = CursorTrack()
    private var clock = RecordingClock()
    private var timer: Timer?
    /// The recorded area in AppKit's global coordinates, or nil once there isn't one (a window that closed).
    private let area: () -> CGRect?
    private let pointer: () -> CGPoint
    private let now: () -> Date

    init(
        area: @escaping () -> CGRect?, pointer: @escaping () -> CGPoint = { NSEvent.mouseLocation },
        now: @escaping () -> Date = { .now }
    ) {
        self.area = area
        self.pointer = pointer
        self.now = now
    }

    func start() {
        clock.begin(at: now())
        track = CursorTrack()
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / CursorTrack.rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func pause() { clock.pause(at: now()) }

    func resume() { clock.resume(at: now()) }

    /// Takes one sample now, unless held or the area is gone.
    func sample() {
        guard clock.isRunning, let area = area() else { return }
        let spot = CursorTrack.fraction(of: pointer(), in: area)
        track.add(.init(time: clock.elapsed(at: now()), x: spot.x, y: spot.y))
    }

    func stop() -> CursorTrack {
        sample()
        timer?.invalidate()
        timer = nil
        return track
    }
}
