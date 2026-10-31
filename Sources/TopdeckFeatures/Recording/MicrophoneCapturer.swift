// SPDX-License-Identifier: MIT
// Adapted from Snapzy (https://github.com/duongductrong/Snapzy) at 77d3d3f: Features/Recording/MicrophoneAudioCapturer.swift.
// Copyright (c) 2026, Trong Duong Duc. BSD 3-Clause License; see THIRD_PARTY_NOTICES.md.
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import TopdeckCore

/// The default microphone, as sample buffers for the recording's writer. It uses an `AVCaptureSession` rather
/// than ScreenCaptureKit's own microphone output, which needs macOS 15. macOS asks for permission the first
/// time (`ask()`), before a recording starts and not in the middle of one.
final class MicrophoneCapturer: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "net.icuai.topdeck.recording.microphone", qos: .userInteractive)
    private let output = AVCaptureAudioDataOutput()
    private let onSample: @Sendable (CMSampleBuffer) -> Void

    init(onSample: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.onSample = onSample
        super.init()
    }

    /// Whether Topdeck may use the microphone, asking the first time. A refusal is final until the user changes
    /// it in System Settings, where the answer comes straight back.
    static func ask() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    /// Starts listening; false when there is no microphone or it can't be opened.
    func start() -> Bool {
        guard let device = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { return false }
        session.addInput(input)
        output.audioSettings = RecordingEncoding.microphoneCaptureSettings()
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        queue.async { [session] in session.startRunning() }
        return true
    }

    func stop() {
        output.setSampleBufferDelegate(nil, queue: nil)
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from: AVCaptureConnection) {
        if sampleBuffer.isValid { onSample(sampleBuffer) }
    }
}
