// SPDX-License-Identifier: MIT
import SwiftUI

extension Deck {
    /// Windows that float over the desktop, outside the deck: the command bar, the window switcher and
    /// the capture editor. A step lighter than the deck's pure black so they read against a dark app.
    public enum Floating {
        /// The command bar's and the switcher's panel.
        public static let panel = Color(hex: 0x121214)
        /// The command bar's footer.
        public static let panelFooter = Color(hex: 0x0C0C0E)
        /// The capture editor's window.
        public static let window = Color(hex: 0x141416)
        /// A window's preview, behind its thumbnail.
        public static let well = Color(hex: 0x23262B)
        /// Corner radii: the command bar, the switcher, and a pinned note.
        public static let barRadius: CGFloat = 18
        public static let switcherRadius: CGFloat = 22
        public static let noteRadius: CGFloat = 13
    }

    /// Pinned notes sit on the desktop beside any app, so they stay light paper whatever the deck is.
    public enum Paper {
        /// Text on every paper colour.
        public static let ink = Color(hex: 0x1C1C1E)
        /// A note with no colour.
        public static let plain = Color(hex: 0xF2F2F4)
        public static let yellow = Color(hex: 0xFFE27A)
        public static let orange = Color(hex: 0xFFC98A)
        public static let red = Color(hex: 0xFFB1AB)
        public static let pink = Color(hex: 0xFFC4DD)
        public static let purple = Color(hex: 0xD9C9FF)
        public static let blue = Color(hex: 0xA9E1FF)
        public static let mint = Color(hex: 0xA6EDDD)
        public static let green = Color(hex: 0xB9F0C4)
        /// The hover bar on a note, and a button lit in it.
        public static let bar = Color.black.opacity(0.09)
        public static let barOn = Color.black.opacity(0.14)
        /// A button's icon in the bar, and the lit one.
        public static let icon = Color(hex: 0x3A3A3C)
        public static let iconOn = Color(hex: 0x000000)
    }
}
