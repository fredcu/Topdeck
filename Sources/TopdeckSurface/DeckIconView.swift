// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

extension DeckIcon {
    /// A complete SVG document: black strokes on the 24-unit grid, which template rendering tints.
    var svg: String {
        "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='#000' stroke-width='2' "
            + "stroke-linecap='round' stroke-linejoin='round'>\(shapes)</svg>"
    }

    /// Each icon is made once; macOS draws SVG natively, sharp at any size.
    @MainActor private static var images: [DeckIcon: NSImage] = [:]

    /// The icon as a template image, which takes the color it's drawn in.
    @MainActor public var image: NSImage? {
        if let cached = Self.images[self] { return cached }
        guard let image = NSImage(data: Data(svg.utf8)) else { return nil }
        image.isTemplate = true
        Self.images[self] = image
        return image
    }

    /// The icon for an SF Symbol a live activity names, where the deck has its own; nil otherwise.
    public static func matching(symbol: String) -> DeckIcon? {
        switch symbol {
        case "hand.raised.fill": .hand
        case "checkmark.circle.fill": .check
        case "timer", "alarm.fill": .clock
        case "calendar", "video.fill": .calendar
        case "tray.and.arrow.down.fill": .share
        case let name where name.hasPrefix("speaker"): .volume
        default: nil
        }
    }
}

/// A deck icon, tinted by the foreground style, at 16 points unless sized.
public struct DeckIconView: View {
    let icon: DeckIcon
    let size: CGFloat

    public init(_ icon: DeckIcon, size: CGFloat = 16) {
        self.icon = icon
        self.size = size
    }

    public var body: some View {
        Group {
            if let image = icon.image {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)  // the control around it says what it does
    }
}
