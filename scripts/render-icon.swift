// SPDX-License-Identifier: MIT
// Renders App/Assets.xcassets/AppIcon.appiconset and MenuBarGlyph.imageset from docs/design/icon-paper.svg.
// AppKit draws the SVG itself, so it needs no tool or package:
//
//     swift scripts/render-icon.swift                 # from the repository's root
//     swift scripts/render-icon.swift 1024 out.png    # one app icon size, to look at
//
// At 16 points the second line and the dot are left out: they turn to mud, and the notch is what reads.
import AppKit

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = try String(contentsOf: root.appending(path: "docs/design/icon-paper.svg"), encoding: .utf8)

/// The icon's SVG, without its second line and dot when `simple`.
func icon(simple: Bool) -> String {
    guard simple else { return source }
    var parts = source.components(separatedBy: "<")
    parts.removeAll { $0.hasPrefix("rect x=\"30\" y=\"77\"") || $0.hasPrefix("circle ") }
    return parts.enumerated().map { $0.offset == 0 ? $0.element : "<" + $0.element }.joined()
}

/// The menu bar's template glyph: the notch and the two lines, in black, the second one fainter.
let glyph = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="16 20 88 72">
    <path d="M20 26h80v2a8 8 0 0 1-8 8h-4c-5 0-7 2-8 6-1 6-5 10-11 10H51c-6 0-10-4-11-10-1-4-3-6-8-6h-4a8 8 0 0 1-8-8Z" fill="#000"/>
    <rect x="30" y="62" width="60" height="9" rx="4.5" fill="#000"/>
    <rect x="30" y="77" width="44" height="9" rx="4.5" fill="#000" fill-opacity="0.55"/>
    </svg>
    """

func render(_ svg: String, pixels: Int, canvas: CGSize? = nil, to url: URL) throws {
    guard let image = NSImage(data: Data(svg.utf8)) else { throw CocoaError(.fileReadCorruptFile) }
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let side = CGFloat(pixels)
    // The glyph keeps its proportions and sits in the middle of a square canvas.
    let size = image.size
    let scale = canvas == nil ? side / max(size.width, size.height) : (side * 0.9) / max(size.width, size.height)
    let drawn = CGSize(width: size.width * scale, height: size.height * scale)
    image.draw(
        in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let arguments = CommandLine.arguments.dropFirst()
if let first = arguments.first, let pixels = Int(first), let out = arguments.dropFirst().first {
    try render(icon(simple: pixels <= 32), pixels: pixels, to: URL(filePath: out))
    exit(0)
}

let assets = root.appending(path: "App/Assets.xcassets")
let set = assets.appending(path: "AppIcon.appiconset")
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = scale == 1 ? "icon-\(points).png" : "icon-\(points)@2x.png"
        // The 16 point icon, at either scale, is the simple one.
        try render(icon(simple: points == 16), pixels: pixels, to: set.appending(path: name))
    }
}
let glyphs = assets.appending(path: "MenuBarGlyph.imageset")
try render(glyph, pixels: 18, canvas: CGSize(width: 18, height: 18), to: glyphs.appending(path: "glyph.png"))
try render(glyph, pixels: 36, canvas: CGSize(width: 18, height: 18), to: glyphs.appending(path: "glyph@2x.png"))
