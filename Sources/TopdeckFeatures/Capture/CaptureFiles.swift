// SPDX-License-Identifier: MIT
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Captures as files: PNG data, and the folder captures sent to the Shelf are kept in, on this Mac.
enum CaptureFiles {
    /// `scale` is pixels per point, kept in the file as its resolution so it opens at the size it was taken.
    static func png(_ image: CGImage, scale: CGFloat = 1) -> Data? {
        let data = NSMutableData()
        let type = UTType.png.identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// "Screenshot 2026-10-30 at 14.03.22", the way macOS names its own.
    static func name(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: date))"
    }

    /// Writes `data` as `<name>.png` in `folder`, adding " 2", " 3"… when a capture already has the
    /// name. Returns where it went.
    static func save(_ data: Data, named name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appending(path: "\(name).png")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(name) \(number).png")
            number += 1
        }
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    /// ~/Library/Application Support/Topdeck/Captures.
    static var folder: URL { AppSupport.file("Captures") }
}

/// A capture's image handed between threads. Core Graphics images don't change once made.
struct CaptureImage: @unchecked Sendable {
    let image: CGImage
    /// Pixels per point: 2 on a Retina display.
    let scale: CGFloat

    var pointSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }
}
