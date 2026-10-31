// SPDX-License-Identifier: MIT
// Adapted from Snapzy (https://github.com/duongductrong/Snapzy) at 77d3d3f: Features/Recording/RecordingPauseTimeline.swift,
// Services/Capture/ScreenRecordingManager.swift (encoding settings and the size limits).
// Copyright (c) 2026, Trong Duong Duc. BSD 3-Clause License; see THIRD_PARTY_NOTICES.md.
import AVFoundation
import CoreMedia
import Foundation

/// What a recording is of: a whole display, or one window.
public enum RecordingTarget: Equatable, Sendable {
    case screen(CGDirectDisplayID)
    case window(CGWindowID)

    var isWindow: Bool {
        if case .window = self { true } else { false }
    }
}

/// What a recording takes along. All three are remembered between recordings.
public struct RecordingOptions: Equatable, Sendable {
    public var systemAudio = false
    public var microphone = false
    /// A ring where each mouse click lands, drawn into the picture. Screen recordings only: a window's own
    /// picture has nowhere to put it.
    public var showClicks = true

    public init(systemAudio: Bool = false, microphone: Bool = false, showClicks: Bool = true) {
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.showClicks = showClicks
    }

    static let systemAudioKey = "recording.systemAudio"
    static let microphoneKey = "recording.microphone"
    static let showClicksKey = "recording.showClicks"

    init(defaults: UserDefaults) {
        self.init(
            systemAudio: defaults.bool(forKey: Self.systemAudioKey),
            microphone: defaults.bool(forKey: Self.microphoneKey),
            showClicks: defaults.object(forKey: Self.showClicksKey) as? Bool ?? true)
    }

    func save(to defaults: UserDefaults) {
        defaults.set(systemAudio, forKey: Self.systemAudioKey)
        defaults.set(microphone, forKey: Self.microphoneKey)
        defaults.set(showClicks, forKey: Self.showClicksKey)
    }
}

/// Why a recording ended on its own. The file is kept, and the user is told once.
enum RecordingFailure: Error, Equatable, Sendable {
    case permissionRevoked
    case diskFull
    case windowClosed
    case displayGone
    case writerFailed
    case streamFailed

    /// What the notch says, in a few words.
    var message: String {
        switch self {
        case .permissionRevoked: "Recording stopped: Screen Recording was turned off"
        case .diskFull: "Recording stopped: the disk is full"
        case .windowClosed: "Recording stopped: the window closed"
        case .displayGone: "Recording stopped: the display went away"
        case .writerFailed, .streamFailed: "Recording stopped unexpectedly"
        }
    }

    /// The failure an error from the writer or the stream stands for. `hasAccess` is whether the Mac still
    /// lets Topdeck record the screen, `windowExists` whether a window target is still on the Mac.
    static func classify(_ error: Error, hasAccess: Bool, windowExists: Bool = true) -> RecordingFailure {
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain, nsError.code == AVError.diskFull.rawValue { return .diskFull }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError { return .diskFull }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) { return .diskFull }
        // The writer wraps the system's error one level down.
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== nsError {
            let inner = classify(underlying, hasAccess: hasAccess, windowExists: windowExists)
            if inner == .diskFull { return inner }
        }
        if !hasAccess { return .permissionRevoked }
        if !windowExists { return .windowClosed }
        // ScreenCaptureKit's error codes (SCStreamError.Code).
        switch nsError.code {
        case -3801: return .permissionRevoked
        case -3813, -3815: return .windowClosed
        case -3814: return .displayGone
        default: return nsError.domain == AVFoundationErrorDomain ? .writerFailed : .streamFailed
        }
    }

    /// Free space under which a recording stops before the disk is full, in bytes.
    static let lowDiskBytes: Int64 = 200_000_000
}

/// The recording's clock: when it began and how long it has been held, so the length shown is what was
/// recorded and not what the wall clock says.
struct RecordingClock: Equatable, Sendable {
    private(set) var start: Date?
    private(set) var heldSince: Date?
    private(set) var held: TimeInterval = 0

    var isRunning: Bool { start != nil && heldSince == nil }
    var isPaused: Bool { heldSince != nil }

    mutating func begin(at now: Date) {
        start = now
        heldSince = nil
        held = 0
    }

    mutating func pause(at now: Date) {
        guard start != nil, heldSince == nil else { return }
        heldSince = now
    }

    mutating func resume(at now: Date) {
        guard let since = heldSince else { return }
        held += max(0, now.timeIntervalSince(since))
        heldSince = nil
    }

    /// Seconds recorded by `now`, not counting the time held.
    func elapsed(at now: Date) -> TimeInterval {
        guard let start else { return 0 }
        return max(0, (heldSince ?? now).timeIntervalSince(start) - held)
    }

    /// The moment a clock that ran since then would read `elapsed(at:)`: what the closed notch counts from.
    func countsFrom(at now: Date) -> Date { now.addingTimeInterval(-elapsed(at: now)) }
}

/// Maps capture-clock sample timestamps onto the written timeline, cutting out paused spans.
///
/// Pause and resume points are measured on the host time clock, the same clock ScreenCaptureKit and
/// AVCaptureSession stamp samples with, so each sample is classified by its own timestamp rather than by
/// when it happens to reach the writer queue.
struct RecordingPauseTimeline: Sendable {
    /// Total paused time removed from samples captured after the latest resume.
    private(set) var accumulatedOffset: CMTime = .zero
    private var pausedAt: CMTime?
    private var resumedAt: CMTime?
    private(set) var lastVideoTime: CMTime?

    var isPaused: Bool { pausedAt != nil }

    mutating func pause(at hostTime: CMTime) {
        guard pausedAt == nil, hostTime.isNumeric else { return }
        pausedAt = hostTime
    }

    mutating func resume(at hostTime: CMTime) {
        guard let pausedAt, hostTime.isNumeric else { return }
        let pausedDuration = CMTimeSubtract(hostTime, pausedAt)
        if pausedDuration > .zero {
            accumulatedOffset = CMTimeAdd(accumulatedOffset, pausedDuration)
        }
        self.pausedAt = nil
        resumedAt = CMTimeMaximum(hostTime, pausedAt)
    }

    /// Output timestamp for a sample, or nil when it was captured while paused. Samples captured before the
    /// latest resume but delivered after it are dropped too.
    func outputTime(for sourceTime: CMTime) -> CMTime? {
        guard sourceTime.isNumeric else { return nil }
        if let pausedAt, sourceTime >= pausedAt { return nil }
        if let resumedAt, sourceTime < resumedAt { return nil }
        return accumulatedOffset > .zero ? CMTimeSubtract(sourceTime, accumulatedOffset) : sourceTime
    }

    /// Like `outputTime(for:)`, but also rejects frames that would not advance the video track: the writer
    /// fails the whole file on a presentation time that does not increase.
    mutating func acceptVideoFrame(at sourceTime: CMTime) -> CMTime? {
        guard let output = outputTime(for: sourceTime) else { return nil }
        if let lastVideoTime, output <= lastVideoTime { return nil }
        lastVideoTime = output
        return output
    }
}

/// How a recording is encoded: H.264 in MP4 at 60 frames a second, and AAC audio.
enum RecordingEncoding {
    static let framesPerSecond = 60
    static let sampleRate = 48_000
    static let channels = 2
    static let audioBitrate = 128_000

    /// Bits per pixel per frame for screen content, with a floor that keeps text legible and a cap that
    /// spares the encoder.
    static let bitsPerPixelPerFrame = 0.2
    static let minimumBitrate = 2_500_000
    static let maximumBitrate = 60_000_000

    static func bitrate(width: Int, height: Int, fps: Int = framesPerSecond) -> Int {
        let wanted = Double(width) * Double(height) * Double(fps) * bitsPerPixelPerFrame
        return Int(min(max(wanted, Double(minimumBitrate)), Double(maximumBitrate)).rounded())
    }

    static func videoSettings(width: Int, height: Int, fps: Int = framesPerSecond) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate(width: width, height: height, fps: fps),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    /// Stereo AAC, for the system audio and the microphone alike.
    static func audioSettings() -> [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: audioBitrate,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
    }

    /// The microphone is asked for 48 kHz float PCM at its source, so a Bluetooth headset's 16 kHz is resampled
    /// with a proper filter and not appended raw to the 48 kHz encoder.
    static func microphoneCaptureSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// The H.264 encoder takes at most 36 864 macroblocks a frame, and at 60 frames a second the level's budget
    /// leaves 34 560: a 5K or 6K display is scaled down to fit, keeping its shape, on even sides.
    static func fittedSize(width: Int, height: Int, fps: Int = framesPerSecond) -> (width: Int, height: Int) {
        let budget = min(36_864, 2_073_600 / max(fps, 1))
        func blocks(_ w: Int, _ h: Int) -> Int { ((w + 15) / 16) * ((h + 15) / 16) }
        func even(_ value: Double) -> Int { max(2, Int(value.rounded(.down)) / 2 * 2) }
        var (w, h) = (even(Double(width)), even(Double(height)))
        var scale = 1.0
        for _ in 0..<12 where blocks(w, h) > budget {
            scale *= (Double(budget) / Double(blocks(w, h))).squareRoot() * 0.999
            (w, h) = (even(Double(width) * scale), even(Double(height) * scale))
        }
        return (w, h)
    }
}
