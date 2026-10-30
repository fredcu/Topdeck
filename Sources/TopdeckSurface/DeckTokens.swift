// SPDX-License-Identifier: MIT
import SwiftUI

/// The deck's design tokens (docs/design-spec.md). Every view in the deck takes its colors, radii,
/// spacing and type from here, never from literals.
public enum Deck {
    // MARK: Colors

    /// The panel: pure black, flush with the hardware notch.
    public static let deck = Color(hex: 0x000000)
    /// A card's fill.
    public static let card = Color(hex: 0x151517)
    /// A card raised above another card, or a field inside one.
    public static let cardRaised = Color(hex: 0x1F1F22)
    /// Controls: a selected pill, a button, a track.
    public static let control = Color(hex: 0x2A2A2E)
    /// A one-point outline or divider.
    public static let hairline = Color.white.opacity(0.09)
    /// Primary text.
    public static let text = Color(hex: 0xF5F5F7)
    /// Secondary text.
    public static let secondary = Color(hex: 0xBDBDC4)
    /// Tertiary text, and anything switched off.
    public static let tertiary = Color(hex: 0x8E8E95)
    /// Needs you: a waiting agent, a meeting about to start, the active warning. Never decoration.
    public static let signal = Color(hex: 0xFFB340)
    /// State: on, done, running.
    public static let go = Color(hex: 0x32D74B)
    /// State: failed, stopped, destructive.
    public static let stop = Color(hex: 0xFF6961)
    /// A signal card's fill, a warm black under the amber outline.
    public static let signalFill = Color(hex: 0x1E1608)
    /// Text on a signal, primary or go fill.
    public static let onFill = Color(hex: 0x000000)

    // MARK: Shape

    /// Corner radii, in points. A pill is a `Capsule`.
    public enum Radius {
        /// The deck's bottom corners.
        public static let deck: CGFloat = 30
        public static let card: CGFloat = 16
        /// Buttons, fields and rows.
        public static let control: CGFloat = 9
    }

    /// Spacing, in points.
    public enum Metric {
        /// Inside a card.
        public static let cardPadding: CGFloat = 14
        /// Between cards, and between a card's rows.
        public static let gap: CGFloat = 10
        /// The deck's side padding around its body.
        public static let side: CGFloat = 14
        /// The second row's height.
        public static let subRow: CGFloat = 42
        /// A wing's navigation pill.
        public static let navHeight: CGFloat = 27
        /// A button.
        public static let buttonHeight: CGFloat = 32
        /// An icon button's square.
        public static let iconButton: CGFloat = 30
    }
}

extension Color {
    /// sRGB from a 24-bit hex value.
    init(hex: UInt32) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// The deck's type scale. Apply with `.deckText(_:)`, which sets the font and the usual color.
public enum DeckTextStyle: CaseIterable, Sendable {
    /// Timers: Rounded 44.
    case timer
    /// Metrics: Rounded 28.
    case metric
    /// Titles: Bold 20.
    case title
    /// Items: Semibold 15.
    case item
    /// Body: Regular 13.
    case body
    /// Detail: Regular 12, secondary.
    case detail
    /// Quiet detail: Regular 12, tertiary.
    case caption
    /// Commands: Mono 12.
    case command

    /// The size in points.
    public var size: CGFloat {
        switch self {
        case .timer: 44
        case .metric: 28
        case .title: 20
        case .item: 15
        case .body: 13
        case .detail, .caption, .command: 12
        }
    }

    /// The font, with tabular digits so numbers that change keep their width.
    public var font: Font {
        switch self {
        case .timer: .system(size: 44, weight: .semibold, design: .rounded).monospacedDigit()
        case .metric: .system(size: 28, weight: .semibold, design: .rounded).monospacedDigit()
        case .title: .system(size: 20, weight: .bold).monospacedDigit()
        case .item: .system(size: 15, weight: .semibold).monospacedDigit()
        case .body: .system(size: 13).monospacedDigit()
        case .detail, .caption: .system(size: 12).monospacedDigit()
        case .command: .system(size: 12, design: .monospaced)
        }
    }

    /// The color it's usually set in.
    public var color: Color {
        switch self {
        case .detail: Deck.secondary
        case .caption: Deck.tertiary
        default: Deck.text
        }
    }
}

extension View {
    /// Sets `style`'s font and color. Pass a color to override the usual one, such as signal.
    public func deckText(_ style: DeckTextStyle, color: Color? = nil) -> some View {
        font(style.font).foregroundStyle(color ?? style.color)
    }
}
