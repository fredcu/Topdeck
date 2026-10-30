// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import Testing

/// The asset catalog's icons are rendered by a script from the board's SVG; this checks the catalog
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

    /// The 16 point icon drops the back card, so its top rows are the amber card, not the grey one.
    @Test func theSmallestIconsHaveNoBackCard() throws {
        let folder = Self.assets.appending(path: "AppIcon.appiconset")
        func topColor(_ name: String) throws -> NSColor {
            let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: folder.appending(path: name))))
            // Just inside the tile's top edge, over the middle: the back card sits there in the big icons.
            let x = bitmap.pixelsWide / 2
            let y = Int(Double(bitmap.pixelsHigh) * 0.265)
            return try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        }
        let big = try topColor("icon-512@2x.png")
        let small = try topColor("icon-16@2x.png")
        #expect(big.redComponent > small.redComponent + 0.2, "the grey back card shows in the big icon, not the small")
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
