// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import Testing

/// The asset catalog's icons are rendered by scripts/render-icon.swift from the board's SVG; this checks the catalog
/// holds every size the Mac asks for, at the right pixel size.
struct AppIconTests {
    private struct Contents: Decodable {
        struct Image: Decodable {
            var filename: String
            var scale: String
            var size: String
        }
        var images: [Image]
    }

    private static let assets = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "App/Assets.xcassets")

    @Test func everySizeIsThereAtItsPixelSize() throws {
        let folder = Self.assets.appending(path: "AppIcon.appiconset")
        let contents = try JSONDecoder().decode(
            Contents.self, from: Data(contentsOf: folder.appending(path: "Contents.json")))
        #expect(contents.images.count == 10, "16, 32, 128, 256 and 512 points, each at 1x and 2x")
        for image in contents.images {
            let points = try #require(Int(image.size.split(separator: "x")[0]))
            let scale = try #require(Int(image.scale.dropLast()))
            let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: folder.appending(path: image.filename))))
            #expect(bitmap.pixelsWide == points * scale && bitmap.pixelsHigh == points * scale, "\(image.filename)")
        }
        #expect(Set(contents.images.map(\.filename)).count == 10, "no size shares another's file")
    }

    /// The 16 point icon drops the second line and the orange dot, which turn to mud at that size.
    @Test func theSmallestIconsHaveNoDot() throws {
        let folder = Self.assets.appending(path: "AppIcon.appiconset")
        func dotColor(_ name: String) throws -> NSColor {
            let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: folder.appending(path: name))))
            // Where the paper icon puts its dot: 70% across and 67.5% down the 120 unit square.
            let x = Int(Double(bitmap.pixelsWide) * 0.7)
            let y = Int(Double(bitmap.pixelsHigh) * 0.675)
            return try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        }
        #expect(try dotColor("icon-512@2x.png").blueComponent < 0.4, "orange in the big icon")
        #expect(try dotColor("icon-32@2x.png").blueComponent < 0.4, "and at 32 points")
        #expect(try dotColor("icon-16@2x.png").blueComponent > 0.6, "paper at 16 points")
        #expect(try dotColor("icon-16.png").blueComponent > 0.6)
    }

    @Test func theMenuBarGlyphIsATemplate() throws {
        let folder = Self.assets.appending(path: "MenuBarGlyph.imageset")
        let contents = try String(contentsOf: folder.appending(path: "Contents.json"), encoding: .utf8)
        #expect(contents.contains("\"template-rendering-intent\" : \"template\""))
        for (name, pixels) in [("glyph.png", 18), ("glyph@2x.png", 36)] {
            let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: folder.appending(path: name))))
            #expect(bitmap.pixelsWide == pixels && bitmap.hasAlpha)
        }
    }
}
