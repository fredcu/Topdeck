// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import Testing
import TopdeckSurface

@testable import TopdeckFeatures

/// Renders the video editor offscreen at 2x in each of its tools. Always checks that it draws; with SNAPSHOT_DIR
/// set, also writes PNGs there:
///
///     SNAPSHOT_DIR=/tmp/editor swift test --filter EditorSnapshot
@MainActor
struct EditorSnapshotTests {
    /// A screen to record: a wallpaper, a window in it, and a click ring, like the board's preview.
    private func screen() throws -> CGImage {
        let (width, height) = (640, 360)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let wall = CGGradient(
            colorsSpace: space,
            colors: [
                CGColor(srgbRed: 0.17, green: 0.30, blue: 0.49, alpha: 1),
                CGColor(srgbRed: 0.78, green: 0.42, blue: 0.48, alpha: 1),
            ]
                as CFArray, locations: [0, 1])!
        context.drawLinearGradient(
            wall, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
        context.setFillColor(CGColor(srgbRed: 0.10, green: 0.12, blue: 0.17, alpha: 1))
        context.addPath(
            CGPath(
                roundedRect: CGRect(x: 60, y: 40, width: 520, height: 280), cornerWidth: 10, cornerHeight: 10,
                transform: nil))
        context.fillPath()
        context.setFillColor(CGColor(srgbRed: 0.35, green: 0.39, blue: 0.47, alpha: 1))
        context.fill(CGRect(x: 90, y: 270, width: 180, height: 14))
        context.setFillColor(CGColor(srgbRed: 0.23, green: 0.26, blue: 0.33, alpha: 1))
        for (index, line) in [(0, 380.0), (1, 330.0), (2, 280.0), (3, 360.0), (4, 300.0)] {
            context.fill(CGRect(x: 90, y: 238 - CGFloat(index) * 26, width: CGFloat(line), height: 10))
        }
        context.setFillColor(CGColor(srgbRed: 1, green: 0.7, blue: 0.25, alpha: 0.3))
        context.fillEllipse(in: CGRect(x: 470, y: 70, width: 40, height: 40))
        context.setStrokeColor(CGColor(srgbRed: 1, green: 0.7, blue: 0.25, alpha: 1))
        context.setLineWidth(3)
        context.strokeEllipse(in: CGRect(x: 471.5, y: 71.5, width: 37, height: 37))
        return try #require(context.makeImage())
    }

    @Test func theEditorInEachTool() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "EditorShots-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Screen Recording 2026-10-30 at 18.54.00.mp4")
        try await SyntheticVideo.make(
            at: url, seconds: 4, width: 640, height: 360, audio: true, audioTracks: 2, picture: try screen())
        // The pointer wandered across the window, and the file has a system track and a microphone.
        try CursorTrack(
            samples: (0...40).map {
                .init(time: Double($0) / 10, x: 0.35 + 0.35 * Double($0) / 40, y: 0.45 + 0.3 * Double($0) / 40)
            },
            audio: ["system", "microphone"]
        ).save(for: url)
        let model = EditorModel(url: url, saveDelay: .seconds(60))
        await model.load()
        #expect(await eventually { model.thumbnails.allSatisfy { $0 != nil } && model.previewStill != nil })
        #expect(model.canFollowCursor && model.audioLabels == ["System audio", "Microphone"])

        // The board's state: the first gradient behind the video, a zoom, the trim a little in from both ends.
        model.apply { $0.background = BackgroundFill.presets[0] }
        model.setTrim(.start, to: 0.4)
        model.setTrim(.end, to: 3.4)
        model.seek(to: 1.8)
        model.addZoom()
        model.updateZoom(try #require(model.selectedZoom).id) {
            $0.target = CGPoint(x: 0.72, y: 0.8)
            $0.start = 1.4
            $0.duration = 1.2
        }
        model.tool = .trim
        try render(model, name: "R3d-Editor-trim")

        // Without the pointer it is a target to pick.
        model.tool = .zoom
        model.updateZoom(try #require(model.selectedZoom).id) { $0.follows = false }
        try render(model, name: "R3d-Editor-zoom")

        model.tool = .crop
        model.apply { $0.crop = CropRegion(x: 0.15, y: 0.1, width: 0.7, height: 0.8) }
        try render(model, name: "R3d-Editor-crop")

        model.tool = .speed
        model.seek(to: 0.6)
        model.addSpeed()
        try render(model, name: "R3d-Editor-speed")

        model.tool = .audio
        model.apply { $0.setAudio(AudioTrackSetting(volume: 1, muted: true), at: 1) }
        try render(model, name: "R3d-Editor-audio")

        model.tool = .background
        model.apply { $0.background = .none }
        try render(model, name: "R3d-Editor-nobackground")
        model.close()
    }

    @Test func theExportBannerInEachState() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "EditorBanner-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "clip.mp4")
        try await SyntheticVideo.make(at: url, seconds: 6, width: 640, height: 360, picture: try screen())
        let model = EditorModel(url: url, saveDelay: .seconds(60))
        await model.load()
        #expect(await eventually { model.previewStill != nil })
        model.export()
        #expect(model.isExporting)
        try render(model, name: "R3d-Editor-exporting", settle: 0.05)
        #expect(await eventually { !model.isExporting })
        try render(model, name: "R3d-Editor-exported", settle: 0.05)
        model.close()
    }

    @Test func aFileThatFailsToOpenShowsOneLine() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "EditorFail-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "broken.mp4")
        try Data("no".utf8).write(to: url)
        let model = EditorModel(url: url)
        await model.load()
        try render(model, name: "R3d-Editor-failed")
    }

    @Test func theSmallestWindowStillHoldsEverything() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "EditorSmall-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "clip.mp4")
        try await SyntheticVideo.make(at: url, seconds: 2, width: 640, height: 360, audio: true, picture: try screen())
        let model = EditorModel(url: url, saveDelay: .seconds(60))
        await model.load()
        #expect(await eventually { model.thumbnails.allSatisfy { $0 != nil } && model.previewStill != nil })
        model.apply { $0.background = BackgroundFill.presets[1] }
        model.addZoom()
        try render(model, name: "R3d-Editor-smallest", size: CGSize(width: 820, height: 480))
        model.close()
    }

    private func render(
        _ model: EditorModel, name: String, size: CGSize = CGSize(width: 960, height: 506), settle: TimeInterval = 0.2
    ) throws {
        let host = NSHostingView(rootView: VideoEditorView(model: model).frame(width: size.width, height: size.height))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now + settle)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide == Int(size.width * 2))
        if let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(filePath: directory).appending(path: "\(name).png"))
        }
    }
}
