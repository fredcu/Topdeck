// SPDX-License-Identifier: MIT
import AppKit
import Testing

@testable import TopdeckFeatures

/// Why Clipboard showed no pictures: what a pasteboard really offers for a copied image. On a private
/// pasteboard, never the user's own clipboard.
@MainActor
struct ClipboardImageTests {
    private let pasteboard = NSPasteboard(name: .init("TopdeckImageTests.\(UUID().uuidString)"))
    private let folder = FileManager.default.temporaryDirectory.appending(path: "ClipboardImages-\(UUID().uuidString)")

    private func recording() throws -> ClipboardFeature {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clipboard = ClipboardFeature(
            pasteboard: pasteboard, defaults: UserDefaults(suiteName: "CI-\(UUID())")!,
            storeURL: folder.appending(path: "clipboard.json"), imagesURL: folder.appending(path: "Clipboard"),
            frontmostApp: { ("com.apple.Preview", "Preview") })
        clipboard.phase = .background
        clipboard.startRecording()
        return clipboard
    }

    /// A solid picture of this many pixels.
    private func bitmap(_ width: Int, _ height: Int) throws -> NSBitmapImageRep {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        if let data = bitmap.bitmapData { data.update(repeating: 200, count: bitmap.bytesPerRow * height) }
        return bitmap
    }

    @Test func aJPEGAloneIsAnImage() throws {
        let clipboard = try recording()
        let jpeg = try #require(try bitmap(40, 30).representation(using: .jpeg, properties: [:]))
        pasteboard.clearContents()
        pasteboard.setData(jpeg, forType: .init("public.jpeg"))
        clipboard.check()
        #expect(clipboard.items.first?.kind == .image, "a photo from Photos or Messages is a JPEG, not a PNG or TIFF")
    }

    @Test func aRetinaScreenCopiedAsTIFFAloneIsAnImage() throws {
        let clipboard = try recording()
        let retina = try bitmap(2880, 1800)
        let tiff = retina.tiffRepresentation ?? Data()
        #expect(tiff.count > ClipboardFeature.largestImage, "uncompressed, it is over the limit that kept it out")
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        clipboard.check()
        let item = try #require(clipboard.items.first)
        #expect(item.kind == .image && item.text == "Image 2880 × 1800", "the limit is on the PNG that is kept")
    }

    @Test func aPictureWithAFileLinkIsStillAPicture() throws {
        let clipboard = try recording()
        let file = folder.appending(path: "Screenshot.png")
        let png = try #require(try bitmap(40, 30).representation(using: .png, properties: [:]))
        try png.write(to: file)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setString(file.absoluteString, forType: .fileURL)
        pasteboard.writeObjects([item])
        clipboard.check()
        #expect(clipboard.items.first?.kind == .image, "the file link must not win over the picture it came with")
    }

    @Test func severalFilesStayFilesEvenWithAPicture() throws {
        let clipboard = try recording()
        let urls = try ["a.png", "b.png"].map { name -> URL in
            let url = folder.appending(path: name)
            try Data(name.utf8).write(to: url)
            return url
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        let small = try bitmap(8, 8)
        pasteboard.setData(small.tiffRepresentation ?? Data(), forType: .tiff)
        clipboard.check()
        #expect(clipboard.items.first?.kind == .files)
    }

    // MARK: Screenshots

    private func png(shade: UInt8 = 200) throws -> Data {
        let picture = try bitmap(40, 30)
        if let data = picture.bitmapData { data.update(repeating: shade, count: picture.bytesPerRow * 30) }
        return try #require(picture.representation(using: .png, properties: [:]))
    }

    @Test func aScreenshotIsKeptFromTopdeckWithoutTouchingTheClipboard() throws {
        let clipboard = try recording()
        let before = pasteboard.changeCount
        clipboard.addScreenshot(png: try png())
        let item = try #require(clipboard.items.first)
        #expect(item.kind == .image && item.source == "Topdeck" && clipboard.image(for: item) != nil)
        #expect(pasteboard.changeCount == before, "the system pasteboard is not written")
    }

    @Test func screenshotsAreSkippedWhileTheHistoryIsOff() throws {
        let clipboard = try recording()
        clipboard.stopRecording()
        clipboard.addScreenshot(png: try png())
        #expect(clipboard.items.isEmpty)
    }

    @Test func aScreenshotAlsoCopiedStaysOneItem() throws {
        let clipboard = try recording()
        let shot = try png()
        clipboard.addScreenshot(png: shot)
        pasteboard.clearContents()
        pasteboard.setData(shot, forType: .png)
        clipboard.check()
        #expect(clipboard.items.count == 1 && clipboard.items.first?.source == "Topdeck", "copied after it was kept")

        let other = try png(shade: 90)
        pasteboard.clearContents()
        pasteboard.setData(other, forType: .png)
        clipboard.check()
        clipboard.addScreenshot(png: other)
        #expect(clipboard.items.count == 2, "kept after it was copied: still one item for that picture")
        #expect(Set(clipboard.items.compactMap(\.digest)).count == 2)
    }

    @Test func screenshotsFollowTheHistoryCapacity() throws {
        let clipboard = try recording()
        for shade in 0..<(ClipboardFeature.capacity + 3) {
            clipboard.addScreenshot(png: try png(shade: UInt8(shade)))
        }
        #expect(clipboard.items.count == ClipboardFeature.capacity)
        let kept =
            (try? FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "Clipboard").path)) ?? []
        #expect(kept.count == ClipboardFeature.capacity, "the oldest pictures' files go with them")
    }

    @Test func filtersShowOneKind() throws {
        let clipboard = try recording()
        clipboard.addScreenshot(png: try png())
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/page", forType: .string)
        clipboard.check()
        pasteboard.clearContents()
        pasteboard.setString("plain words", forType: .string)
        clipboard.check()
        #expect(clipboard.search("", filter: .all).count == 3)
        #expect(clipboard.search("", filter: .images).map(\.kind) == [.image])
        #expect(clipboard.search("", filter: .links).map(\.kind) == [.link])
        #expect(clipboard.search("words", filter: .text).map(\.kind) == [.text])
        #expect(clipboard.search("words", filter: .images).isEmpty)
        #expect(clipboard.search("", filter: .files).isEmpty)
    }
}
