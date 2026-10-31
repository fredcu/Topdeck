// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckCore

/// The deck's design tokens (docs/design-spec.md). Every view in the deck takes its colors, radii,
/// spacing and type from here, never from literals.
public enum Deck {
    // MARK: Colors

    /// The panel at its top: pure black, flush with the hardware notch.
    public static let deck = Color(hex: 0x000000)
    /// The panel from `gradientLength` points below the notch to the bottom.
    public static let body = Color(hex: 0x10131B)
    /// A card's fill.
    public static let card = Color(hex: 0x1A1F2B)
    /// A card raised above another card, or a field inside one.
    public static let cardRaised = Color(hex: 0x232936)
    /// Controls: a selected pill, a button, a track.
    public static let control = Color(hex: 0x2E3545)
    /// A one-point outline or divider.
    public static let hairline = Color(.sRGB, red: 190 / 255, green: 205 / 255, blue: 235 / 255, opacity: 0.11)
    /// Primary text.
    public static let text = Color(hex: 0xF3F5FA)
    /// Secondary text.
    public static let secondary = Color(hex: 0xB7BFD0)
    /// Tertiary text, and anything switched off.
    public static let tertiary = Color(hex: 0x8791A6)
    /// A space's label while it isn't the open one.
    public static let navInactive = Color(hex: 0xA4AEC2)
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
    /// Text on the Now accent's solid fill, such as today's circle in the month.
    public static let onAccent = Color(hex: 0x07121F)

    /// How far below the notch the panel takes to go from black to `body`.
    public static let gradientLength: CGFloat = 55

    /// The stops of the panel's fill for a deck `height` points tall under a notch `notch` points tall: black
    /// down to the notch, then a vertical gradient over `gradientLength` points to `body`, which holds to the
    /// bottom.
    static func panelStops(height: CGFloat, notch: CGFloat) -> [Gradient.Stop] {
        let height = max(height, 1)
        let start = min(max(notch / height, 0), 1)
        let end = min(start + gradientLength / height, 1)
        return [
            .init(color: deck, location: 0), .init(color: deck, location: start),
            .init(color: body, location: end), .init(color: body, location: 1),
        ]
    }

    /// The panel's fill, from `panelStops`.
    public static func panelFill(height: CGFloat, notch: CGFloat) -> LinearGradient {
        LinearGradient(stops: panelStops(height: height, notch: notch), startPoint: .top, endPoint: .bottom)
    }

    /// The accent of each space: the open space's label, its selected states and its primary buttons.
    public enum Accent {
        public static let now = Color(hex: 0x6CB2FF)
        public static let shelf = Color(hex: 0x3FD6C5)
        public static let clipboard = Color(hex: 0xB49CFF)
        public static let tools = Color(hex: 0xFF9F5A)
        public static let agents = Color(hex: 0xFFB340)
        public static let mac = Color(hex: 0x5EDB8A)
    }

    /// The warm end of a forecast range bar, and the cool end, with the yellow between.
    public enum Range {
        public static let cool = Color(hex: 0x6CB2FF)
        public static let mild = Color(hex: 0xFFD166)
        public static let warm = Color(hex: 0xFF9F5A)
    }

    /// The colours of a note's square in Now's list and of the dots that pick it.
    public enum Note {
        public static let red = Color(hex: 0xF5B5B0)
        public static let orange = Color(hex: 0xF7C59F)
        public static let yellow = Color(hex: 0xF7E08A)
        public static let green = Color(hex: 0xB8E7C0)
        public static let mint = Color(hex: 0xB3E8DC)
        public static let blue = Color(hex: 0xB8D8F7)
        public static let purple = Color(hex: 0xD8C7F5)
        public static let pink = Color(hex: 0xF5BFD8)
    }

    /// The tints of a file's tile on the Shelf, by kind. A tile runs from the colour to a darker mix of it.
    public enum Kind {
        public static let document = Color(hex: 0x2E6CB8)
        public static let image = Color(hex: 0x7A4FCF)
        public static let sheet = Color(hex: 0x1E8E7E)
        public static let video = Color(hex: 0xB5562B)
        public static let archive = Color(hex: 0x3B4660)
        public static let audio = Color(hex: 0xA8325E)
        public static let code = Color(hex: 0x4F7A2F)
        public static let other = Color(hex: 0x4A5470)
    }

    // MARK: Shape

    /// Corner radii, in points. A pill is a `Capsule`.
    public enum Radius {
        /// The deck's bottom corners.
        public static let deck: CGFloat = 30
        public static let card: CGFloat = 16
        /// A tool tile.
        public static let tile: CGFloat = 12
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
        /// Now's second row, tall enough for the clock.
        public static let nowRow: CGFloat = 46
        /// The deck's side padding on the second row and on Now's columns.
        public static let inset: CGFloat = 18
        /// Between Now's columns, around their hairlines.
        public static let columnGap: CGFloat = 14
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
    /// Now's clock: Rounded 34.
    case clock
    /// The weather's large temperature: Rounded 32.
    case temperature
    /// The temperature beside a player: Rounded 26.
    case temperatureMedium
    /// The temperature in the smallest deck's player: Rounded 20.
    case temperatureSmall
    /// A figure in a row of figures: Semibold 12.
    case figure
    /// The line being sung: Bold 15.
    case lyric
    /// The line being sung in the smallest deck: Bold 13.
    case lyricSmall

    /// The size in points.
    public var size: CGFloat {
        switch self {
        case .timer: 44
        case .metric: 28
        case .title: 20
        case .item: 15
        case .body: 13
        case .detail, .caption, .command, .figure: 12
        case .clock: 34
        case .temperature: 32
        case .temperatureMedium: 26
        case .temperatureSmall: 20
        case .lyric: 15
        case .lyricSmall: 13
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
        case .clock: .system(size: 34, weight: .semibold, design: .rounded).monospacedDigit()
        case .temperature: .system(size: 32, weight: .semibold, design: .rounded).monospacedDigit()
        case .temperatureMedium: .system(size: 26, weight: .semibold, design: .rounded).monospacedDigit()
        case .temperatureSmall: .system(size: 20, weight: .semibold, design: .rounded).monospacedDigit()
        case .figure: .system(size: 12, weight: .semibold).monospacedDigit()
        case .lyric: .system(size: 15, weight: .bold)
        case .lyricSmall: .system(size: 13, weight: .bold)
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

extension EnvironmentValues {
    /// The open space's accent. The deck sets it, so selected states, chips and primary buttons take the
    /// colour of the space they are in without naming it.
    @Entry public var deckAccent: Color = Deck.Accent.now
}

extension SpaceID {
    /// The space's accent.
    public var accent: Color {
        switch self {
        case .now: Deck.Accent.now
        case .shelf: Deck.Accent.shelf
        case .clipboard: Deck.Accent.clipboard
        case .tools: Deck.Accent.tools
        case .agents: Deck.Accent.agents
        case .mac: Deck.Accent.mac
        }
    }
}

extension Color {
    /// This colour as a tint behind itself: a selected pill, a primary button.
    public func tint(_ opacity: Double = 0.22) -> Color { self.opacity(opacity) }
}
