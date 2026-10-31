// SPDX-License-Identifier: MIT
import SwiftUI

// The deck's shared components. Screens are built from these, so every one looks like the boards.

// MARK: Cards

/// How a card is filled.
public enum DeckCardStyle: Sendable {
    /// The usual card.
    case standard
    /// A card lifted above another card.
    case raised
    /// A card that needs you: an amber outline on a warm black.
    case signal
}

/// A rounded card with a hairline outline and the deck's padding.
public struct DeckCard<Content: View>: View {
    let style: DeckCardStyle
    let padding: CGFloat
    let content: Content

    public init(
        _ style: DeckCardStyle = .standard, padding: CGFloat = Deck.Metric.cardPadding,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Deck.Radius.card, style: .continuous)
        content
            .padding(padding)
            .background(
                shape.fill(
                    style == .raised ? Deck.cardRaised : style == .signal ? Deck.signalFill : Deck.card)
            )
            .overlay(shape.strokeBorder(style == .signal ? Deck.signal.opacity(0.55) : Deck.hairline, lineWidth: 1))
    }
}

// MARK: Buttons

/// Which button: what it means decides how loud it is.
public enum DeckButtonKind: Sendable {
    /// An ordinary action.
    case standard
    /// The one action to take, white: Allow.
    case primary
    /// An action that needs you, amber: Join.
    case accent
    /// A quiet action with only an outline: Terminal.
    case outline
}

/// A text button, 32 high with a 9 point radius; `compact` is the small one inside a row, and `fill`
/// stretches it, background and all, across the width it's given (the boards' `flex: 1`).
public struct DeckButtonStyle: ButtonStyle {
    let kind: DeckButtonKind
    let compact: Bool
    let fill: Bool

    public init(_ kind: DeckButtonKind = .standard, compact: Bool = false, fill: Bool = false) {
        self.kind = kind
        self.compact = compact
        self.fill = fill
    }

    public func makeBody(configuration: Configuration) -> some View {
        Rendered(kind: kind, compact: compact, fill: fill, configuration: configuration)
    }

    private struct Rendered: View {
        let kind: DeckButtonKind
        let compact: Bool
        let fill: Bool
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: compact ? 7 : Deck.Radius.control, style: .continuous)
            configuration.label
                .font(.system(size: compact ? 12 : 13, weight: .semibold))
                .foregroundStyle(kind == .primary || kind == .accent ? Deck.onFill : Deck.text)
                .lineLimit(1)
                .padding(.horizontal, compact ? 9 : 13)
                .frame(maxWidth: fill ? .infinity : nil)
                .frame(height: compact ? 23 : Deck.Metric.buttonHeight)
                .background(shape.fill(background))
                .overlay { if kind == .outline { shape.strokeBorder(Deck.hairline, lineWidth: 1) } }
                .contentShape(shape)
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
        }

        private var background: Color {
            switch kind {
            case .standard: Deck.control
            case .primary: Deck.text
            case .accent: Deck.signal
            case .outline: .clear
            }
        }
    }
}

/// A square button for one icon, 30 points; `on` lights it, `large` is the 44 point transport size.
public struct DeckIconButtonStyle: ButtonStyle {
    let on: Bool
    let large: Bool

    public init(on: Bool = false, large: Bool = false) {
        self.on = on
        self.large = large
    }

    public func makeBody(configuration: Configuration) -> some View {
        Rendered(on: on, large: large, configuration: configuration)
    }

    private struct Rendered: View {
        let on: Bool
        let large: Bool
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let side = large ? 44 : Deck.Metric.iconButton
            configuration.label
                .foregroundStyle(on ? Deck.text : Deck.secondary)
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Deck.control : .clear))
                .contentShape(Rectangle())
                .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
        }
    }
}

extension ButtonStyle where Self == DeckButtonStyle {
    /// The deck's text button.
    public static func deck(_ kind: DeckButtonKind = .standard, compact: Bool = false, fill: Bool = false)
        -> DeckButtonStyle
    {
        DeckButtonStyle(kind, compact: compact, fill: fill)
    }
}

extension ButtonStyle where Self == DeckIconButtonStyle {
    /// The deck's icon button.
    public static func deckIcon(on: Bool = false, large: Bool = false) -> DeckIconButtonStyle {
        DeckIconButtonStyle(on: on, large: large)
    }
}

/// An icon button with its accessibility label, which is also its tooltip.
public struct DeckIconButton: View {
    let icon: DeckIcon
    let label: String
    let on: Bool
    let action: () -> Void

    public init(_ icon: DeckIcon, label: String, on: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.on = on
        self.action = action
    }

    public var body: some View {
        Button(action: action) { DeckIconView(icon) }
            .buttonStyle(.deckIcon(on: on))
            .help(label)
            .accessibilityLabel(label)
    }
}

// MARK: Navigation

/// A space's label in a wing: a pill, lit when selected, with an optional signal badge. `compact` is
/// the tighter pill a wing falls back to when the deck is at its smallest.
public struct DeckNavItem: View {
    let title: String
    let selected: Bool
    let badge: Int
    let compact: Bool
    let action: () -> Void

    public init(
        _ title: String, selected: Bool, badge: Int = 0, compact: Bool = false, action: @escaping () -> Void
    ) {
        self.title = title
        self.selected = selected
        self.badge = badge
        self.compact = compact
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if badge > 0 { DeckBadge(badge) }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(selected ? Deck.text : Deck.tertiary)
            .fixedSize()
            .padding(.horizontal, compact ? 8 : 12)
            .frame(height: Deck.Metric.navHeight)
            .background(Capsule().fill(selected ? Deck.control : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(title), \(badge) waiting" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The text tabs of the second row: lit when selected, 42 high, 18 apart.
public struct DeckSubTabs<ID: Hashable>: View {
    let items: [ID]
    let selection: ID?
    let title: (ID) -> String
    let select: (ID) -> Void

    public init(_ items: [ID], selection: ID?, title: @escaping (ID) -> String, select: @escaping (ID) -> Void) {
        self.items = items
        self.selection = selection
        self.title = title
        self.select = select
    }

    public var body: some View {
        HStack(spacing: 18) {
            ForEach(items, id: \.self) { item in
                Button {
                    select(item)
                } label: {
                    Text(title(item))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item == selection ? Deck.text : Deck.tertiary)
                        .frame(height: Deck.Metric.subRow)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == selection ? .isSelected : [])
            }
        }
    }
}

/// A small group of options in a tray, one selected: where a note shows, which provider.
public struct DeckSegmented<ID: Hashable>: View {
    let items: [ID]
    let selection: ID?
    let title: (ID) -> String
    let select: (ID) -> Void

    public init(_ items: [ID], selection: ID?, title: @escaping (ID) -> String, select: @escaping (ID) -> Void) {
        self.items = items
        self.selection = selection
        self.title = title
        self.select = select
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                Button {
                    select(item)
                } label: {
                    Text(title(item))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(item == selection ? Deck.text : Deck.tertiary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(item == selection ? Deck.control : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == selection ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Deck.Radius.control, style: .continuous).fill(Deck.cardRaised))
    }
}

// MARK: Rows

/// A list row, at least 38 high: lit when selected. With an action it's a button.
public struct DeckRow<Content: View>: View {
    let selected: Bool
    let action: (() -> Void)?
    let content: Content

    public init(selected: Bool = false, action: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.selected = selected
        self.action = action
        self.content = content()
    }

    public var body: some View {
        if let action {
            Button(action: action) { row }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: Deck.Metric.gap) { content }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Deck.Radius.control, style: .continuous).fill(rowFill))
            .contentShape(Rectangle())
    }

    private var rowFill: Color { selected ? Deck.control : .clear }
}

// MARK: Marks

/// What a dot or a meter means.
public enum DeckTone: Sendable {
    /// Running, on, done.
    case go
    /// Needs you.
    case signal
    /// Failed or stopped.
    case stop
    /// Idle.
    case quiet

    var color: Color {
        switch self {
        case .go: Deck.go
        case .signal: Deck.signal
        case .stop: Deck.stop
        case .quiet: Deck.tertiary
        }
    }
}

/// A count in an amber pill: agents waiting. Black text on signal.
public struct DeckBadge: View {
    let count: Int

    public init(_ count: Int) { self.count = count }

    public var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(Deck.onFill)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(Deck.signal))
    }
}

/// A 7 point status dot.
public struct DeckDot: View {
    let tone: DeckTone

    public init(_ tone: DeckTone = .go) { self.tone = tone }

    public var body: some View {
        Circle().fill(tone.color).frame(width: 7, height: 7).accessibilityHidden(true)
    }
}

/// A 5 point progress bar. `value` is 0 to 1; a signal tone is for a limit that needs attention.
public struct DeckBar: View {
    let value: Double
    let tone: DeckTone?

    public init(_ value: Double, tone: DeckTone? = nil) {
        self.value = value
        self.tone = tone
    }

    public var body: some View {
        let fraction = min(max(value, 0), 1)
        Capsule()
            .fill(Deck.control)
            .frame(height: 5)
            .overlay(alignment: .leading) {
                GeometryReader { track in
                    Capsule().fill(tone?.color ?? Deck.text).frame(width: track.size.width * fraction)
                }
            }
            .accessibilityElement()
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

/// A keyboard key, as in a shortcut: ⌥ Space.
public struct DeckKeyCap: View {
    let key: String

    public init(_ key: String) { self.key = key }

    public var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Deck.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Deck.control))
    }
}

/// A one point divider.
public struct DeckSeparator: View {
    public init() {}

    public var body: some View {
        Rectangle().fill(Deck.hairline).frame(height: 1).accessibilityHidden(true)
    }
}

/// An empty state: one short line, centered, or nothing. Never instructions.
public struct DeckEmptyLine: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text).deckText(.body, color: Deck.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A search field for the second row: a search icon and a field in a raised, rounded box. `takeFocus`
/// is raised by whoever wants the keyboard in it (a shortcut that opened the tab); the field lowers it.
public struct DeckSearchField: View {
    let prompt: String
    @Binding var text: String
    let width: CGFloat
    let takeFocus: Binding<Bool>?
    let submit: () -> Void
    @FocusState private var focused: Bool

    public init(
        _ prompt: String = "Search", text: Binding<String>, width: CGFloat = 220, takeFocus: Binding<Bool>? = nil,
        submit: @escaping () -> Void = {}
    ) {
        self.prompt = prompt
        _text = text
        self.width = width
        self.takeFocus = takeFocus
        self.submit = submit
    }

    public var body: some View {
        HStack(spacing: 8) {
            DeckIconView(.search, size: 13)
            TextField(text: $text, prompt: Text(prompt).foregroundStyle(Deck.tertiary)) { Text(prompt) }
                .textFieldStyle(.plain)
                .font(DeckTextStyle.detail.font)
                .foregroundStyle(Deck.text)
                .focused($focused)
                .onSubmit(submit)
        }
        .foregroundStyle(Deck.tertiary)
        .padding(.horizontal, 10)
        .frame(width: width, height: Deck.Metric.iconButton)
        .background(RoundedRectangle(cornerRadius: Deck.Radius.control, style: .continuous).fill(Deck.cardRaised))
        .onAppear(perform: takeIfAsked)
        .onChange(of: takeFocus?.wrappedValue ?? false) { takeIfAsked() }
        .accessibilityLabel(prompt)
    }

    private func takeIfAsked() {
        guard takeFocus?.wrappedValue == true else { return }
        takeFocus?.wrappedValue = false
        focused = true
    }
}

// MARK: Layout

/// Lays its children side by side, with the deck's gap between them, sharing the width by `weights`
/// (the boards' `1.25fr 1fr`). Every child gets the row's full height.
public struct DeckWeightedRow: Layout {
    let weights: [CGFloat]

    public init(_ weights: [CGFloat]) { self.weights = weights }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let gaps = Deck.Metric.gap * CGFloat(max(subviews.count - 1, 0))
        let used = subviews.indices.map { weights.indices.contains($0) ? weights[$0] : 1 }
        let unit = (bounds.width - gaps) / used.reduce(0, +)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let width = unit * used[index]
            subview.place(
                at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                proposal: .init(width: width, height: bounds.height))
            x += width + Deck.Metric.gap
        }
    }
}

/// Lays its children out left to right and wraps them onto new lines: a row of options that may not
/// fit in one. Each child keeps its own size.
public struct DeckFlow: Layout {
    let spacing: CGFloat

    public init(spacing: CGFloat = 8) { self.spacing = spacing }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: widest, height: y + lineHeight))
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrange(subviews, width: bounds.width).origins
        for (subview, origin) in zip(subviews, origins) {
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), anchor: .topLeading,
                proposal: .unspecified)
        }
    }
}
