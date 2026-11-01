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
    /// The one action to take, tinted in the space's accent: Allow.
    case primary
    /// An action that needs you, amber: Join.
    case accent
    /// A quiet action with only an outline: Terminal.
    case outline
}

/// A text button, 32 high with a 9 point radius; `compact` is the small one inside a row, `slot` the 28
/// high one in Now's request bar, and `fill` stretches it, background and all, across the width it's
/// given (the boards' `flex: 1`).
public struct DeckButtonStyle: ButtonStyle {
    let kind: DeckButtonKind
    let compact: Bool
    let fill: Bool
    let slot: Bool

    public init(_ kind: DeckButtonKind = .standard, compact: Bool = false, fill: Bool = false, slot: Bool = false) {
        self.kind = kind
        self.compact = compact
        self.fill = fill
        self.slot = slot
    }

    public func makeBody(configuration: Configuration) -> some View {
        Rendered(kind: kind, compact: compact, fill: fill, slot: slot, configuration: configuration)
    }

    private struct Rendered: View {
        let kind: DeckButtonKind
        let compact: Bool
        let fill: Bool
        let slot: Bool
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.deckAccent) private var accent

        var body: some View {
            let small = compact || slot
            let shape = RoundedRectangle(
                cornerRadius: compact && !slot ? 7 : Deck.Radius.control, style: .continuous)
            configuration.label
                .font(.system(size: small ? 12 : 13, weight: .semibold))
                .foregroundStyle(kind == .primary ? accent : kind == .accent ? Deck.onFill : Deck.text)
                .lineLimit(1)
                .padding(.horizontal, slot ? 11 : compact ? 9 : 13)
                .frame(maxWidth: fill ? .infinity : nil)
                .frame(height: slot ? 28 : compact ? 23 : Deck.Metric.buttonHeight)
                .background(shape.fill(background))
                .overlay { if kind == .outline { shape.strokeBorder(Deck.hairline, lineWidth: 1) } }
                .contentShape(shape)
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
        }

        private var background: Color {
            switch kind {
            case .standard: Deck.control
            case .primary: accent.tint()
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
    public static func deck(
        _ kind: DeckButtonKind = .standard, compact: Bool = false, fill: Bool = false, slot: Bool = false
    ) -> DeckButtonStyle {
        DeckButtonStyle(kind, compact: compact, fill: fill, slot: slot)
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

// MARK: Chips and fields

/// A small choice in a row of them, 27 high: tinted in the space's accent when picked, an outline when
/// not. A day.
public struct DeckChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.deckAccent) private var accent

    public init(_ title: String, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Deck.Radius.control, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? accent : Deck.secondary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(minWidth: 36, minHeight: Deck.Metric.navHeight)
                .background(shape.fill(selected ? accent.tint() : .clear))
                .overlay { if !selected { shape.strokeBorder(Deck.hairline, lineWidth: 1) } }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A rounded capsule for one preset: 30 minutes, 1 hour. Lit when `on`.
public struct DeckPillButtonStyle: ButtonStyle {
    let on: Bool

    public init(on: Bool = false) { self.on = on }

    public func makeBody(configuration: Configuration) -> some View {
        Rendered(on: on, configuration: configuration)
    }

    private struct Rendered: View {
        let on: Bool
        let configuration: ButtonStyleConfiguration
        @Environment(\.deckAccent) private var accent

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? accent : Deck.text)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minWidth: 34, minHeight: 27)
                .background(Capsule().fill(on ? accent.tint() : Deck.control))
                .contentShape(Capsule())
                .opacity(configuration.isPressed ? 0.75 : 1)
        }
    }
}

extension ButtonStyle where Self == DeckPillButtonStyle {
    /// The deck's preset capsule.
    public static func deckPill(on: Bool = false) -> DeckPillButtonStyle { DeckPillButtonStyle(on: on) }
}

/// A one-line text field in a raised rounded box, 30 high, with an optional icon before the text.
public struct DeckField: View {
    let prompt: String
    let icon: DeckIcon?
    @Binding var text: String
    let onSubmit: () -> Void

    public init(_ prompt: String, text: Binding<String>, icon: DeckIcon? = nil, onSubmit: @escaping () -> Void = {}) {
        self.prompt = prompt
        self.icon = icon
        _text = text
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let icon { DeckIconView(icon, size: 13).foregroundStyle(Deck.tertiary) }
            TextField("", text: $text, prompt: Text(prompt).foregroundColor(Deck.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Deck.text)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, 10)
        .frame(height: Deck.Metric.iconButton)
        .background(RoundedRectangle(cornerRadius: Deck.Radius.control, style: .continuous).fill(Deck.cardRaised))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(prompt)
    }
}

// MARK: Navigation

/// A space's label in a wing: a pill in the space's accent at 18% with accent text when selected, with an
/// optional signal badge. `compact` is the tighter pill a wing falls back to when the deck is at its
/// smallest.
public struct DeckNavItem: View {
    let title: String
    let accent: Color
    let selected: Bool
    let badge: Int
    let compact: Bool
    let action: () -> Void

    public init(
        _ title: String, accent: Color = Deck.Accent.now, selected: Bool, badge: Int = 0, compact: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.accent = accent
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
            .foregroundStyle(selected ? accent : Deck.navInactive)
            .fixedSize()
            .padding(.horizontal, compact ? 8 : 12)
            .frame(height: Deck.Metric.navHeight)
            .background(Capsule().fill(selected ? accent.tint(0.18) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(title), \(badge) waiting" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A small group of options in a tray, one selected: where a note shows, which provider. `compact` is
/// the 26 point tray that sits inside a field, on a black `tray`.
public struct DeckSegmented<ID: Hashable>: View {
    let items: [ID]
    let selection: ID?
    let title: (ID) -> String
    let select: (ID) -> Void
    let compact: Bool

    public init(
        _ items: [ID], selection: ID?, compact: Bool = false, title: @escaping (ID) -> String,
        select: @escaping (ID) -> Void
    ) {
        self.items = items
        self.selection = selection
        self.compact = compact
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
                        .padding(.horizontal, compact ? 9 : 10)
                        .frame(height: compact ? 22 : 26)
                        .background(
                            RoundedRectangle(cornerRadius: compact ? 6 : 7, style: .continuous)
                                .fill(item == selection ? Deck.control : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == selection ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: compact ? 8 : Deck.Radius.control, style: .continuous)
                .fill(compact ? Deck.body : Deck.cardRaised))
    }
}

// MARK: Rows

/// A list row, at least 38 high: tinted in the space's accent when selected. With an action it's a button.
public struct DeckRow<Content: View>: View {
    @Environment(\.deckAccent) private var accent
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

    private var rowFill: Color { selected ? accent.tint(0.16) : .clear }
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

/// A 5 point progress bar in the space's accent. `value` is 0 to 1; a tone is for a state, such as a limit
/// that needs attention.
public struct DeckBar: View {
    let value: Double
    let tone: DeckTone?
    @Environment(\.deckAccent) private var accent

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
                    Capsule().fill(tone?.color ?? accent).frame(width: track.size.width * fraction)
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

// MARK: Controls

/// A sideways slider, as on the Sound board: a 6 point track and a 16 point thumb. Drag or click
/// anywhere along it; VoiceOver adjusts it in steps of five percent.
public struct DeckSlider: View {
    @Environment(\.deckAccent) private var accent
    let level: Double
    let label: String
    let value: String
    let enabled: Bool
    let set: (Double) -> Void

    private static let thumb: CGFloat = 16

    /// `value` is what VoiceOver reads, such as "64%" or "Muted".
    public init(
        _ level: Double, label: String, value: String? = nil, enabled: Bool = true,
        set: @escaping (Double) -> Void
    ) {
        self.level = level
        self.label = label
        self.value = value ?? "\(Int((min(max(level, 0), 1) * 100).rounded())) percent"
        self.enabled = enabled
        self.set = set
    }

    public var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - Self.thumb, 1)
            let x = Self.thumb / 2 + travel * min(max(level, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Deck.control).frame(height: 6)
                Capsule().fill(accent).frame(width: x, height: 6)
                Circle()
                    .fill(Deck.text)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .shadow(color: Deck.deck.opacity(0.6), radius: 2, y: 1)
                    .offset(x: x - Self.thumb / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    set(min(max((drag.location.x - Self.thumb / 2) / travel, 0), 1))
                },
                isEnabled: enabled)
        }
        .frame(height: 22)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityAdjustableAction { direction in
            set(min(max(level + (direction == .increment ? 0.05 : -0.05), 0), 1))
        }
    }
}

/// A slider with what it sets: an optional 24 point lead (an icon, or a button around one), a title in
/// a 92 point column, the slider, and its value in a 36 point column. At least 38 high. `label` is what
/// VoiceOver calls the slider when the visible title is short, such as "Volume".
public struct DeckLevelRow<Lead: View>: View {
    let title: String
    let style: DeckTextStyle
    let level: Double
    let value: String
    let spoken: String?
    let label: String
    let enabled: Bool
    let set: (Double) -> Void
    let lead: Lead?

    public init(
        _ title: String, style: DeckTextStyle = .body, level: Double, value: String, spoken: String? = nil,
        label: String? = nil, enabled: Bool = true, set: @escaping (Double) -> Void, @ViewBuilder lead: () -> Lead
    ) {
        self.title = title
        self.style = style
        self.level = level
        self.value = value
        self.spoken = spoken
        self.label = label ?? title
        self.enabled = enabled
        self.set = set
        self.lead = lead()
    }

    public var body: some View {
        HStack(spacing: Deck.Metric.gap) {
            if let lead { lead.frame(width: 24) }
            Text(title).deckText(style).lineLimit(1).truncationMode(.tail).frame(width: 92, alignment: .leading)
            DeckSlider(level, label: label, value: spoken, enabled: enabled, set: set)
            Text(value).deckText(.detail).lineLimit(1).frame(width: 36, alignment: .leading)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 38)
    }
}

extension DeckLevelRow where Lead == EmptyView {
    /// A row with no lead.
    public init(
        _ title: String, style: DeckTextStyle = .body, level: Double, value: String, spoken: String? = nil,
        label: String? = nil, enabled: Bool = true, set: @escaping (Double) -> Void
    ) {
        self.title = title
        self.style = style
        self.level = level
        self.value = value
        self.spoken = spoken
        self.label = label ?? title
        self.enabled = enabled
        self.set = set
        self.lead = nil
    }
}

/// A tick box for a row in a list you select from.
public struct DeckCheckbox: View {
    @Environment(\.deckAccent) private var accent
    let ticked: Bool
    let label: String
    let toggle: () -> Void

    public init(ticked: Bool, label: String, toggle: @escaping () -> Void) {
        self.ticked = ticked
        self.label = label
        self.toggle = toggle
    }

    public var body: some View {
        Button(action: toggle) {
            let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
            DeckIconView(.check, size: 12)
                .foregroundStyle(Deck.onFill)
                .opacity(ticked ? 1 : 0)
                .frame(width: 18, height: 18)
                .background(shape.fill(ticked ? accent : .clear))
                .overlay(shape.strokeBorder(ticked ? .clear : Deck.tertiary, lineWidth: 1.5))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(ticked ? "Selected" : "Not selected")
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

// MARK: Now

/// The time, large, in the space's accent, in Now's second row. Time only, no date; it moves on each minute.
public struct DeckClock: View {
    @Environment(\.deckAccent) private var accent

    public init() {}

    public var body: some View {
        TimelineView(.everyMinute) { context in
            Text(context.date.formatted(.dateTime.hour().minute())).deckText(.clock, color: accent).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A one-pixel vertical line between Now's columns.
public struct DeckRule: View {
    public init() {}

    public var body: some View {
        Rectangle().fill(Deck.hairline).frame(width: 1).accessibilityHidden(true)
    }
}

/// A figure with a small icon before it, such as the weather's humidity: the icon is an SF Symbol.
/// `label` is the spoken name and the tooltip, since the icon alone doesn't say what it is.
public struct DeckMetricCell: View {
    let symbol: String
    let value: String
    let label: String

    public init(symbol: String, value: String, label: String) {
        self.symbol = symbol
        self.value = value
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Deck.tertiary)
                .frame(width: 14)
            Text(value).deckText(.figure).lineLimit(1).fixedSize()
        }
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// A thin position bar with a round knob, 14 high: drag or click along it, or use the arrow keys when
/// it has the keyboard and VoiceOver's adjust actions. While dragging, `scrub` holds the fraction under
/// the pointer so the readouts around it can follow, and `commit` is called once, on release. Keys and
/// VoiceOver commit at once, a `step` at a time.
public struct DeckScrubber: View {
    let value: Double
    @Binding var scrub: Double?
    let label: String
    let spoken: String
    let step: Double
    let isEnabled: Bool
    let commit: (Double) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.deckAccent) private var accent
    @FocusState private var focused: Bool

    private static let knob: CGFloat = 12

    /// `value` is the position as a fraction. `spoken` is what VoiceOver reads, such as "1:02 of 3:58".
    public init(
        value: Double, scrub: Binding<Double?>, label: String, spoken: String, step: Double, isEnabled: Bool = true,
        commit: @escaping (Double) -> Void
    ) {
        self.value = value
        _scrub = scrub
        self.label = label
        self.spoken = spoken
        self.step = step
        self.isEnabled = isEnabled
        self.commit = commit
    }

    private static func clamp(_ fraction: Double) -> Double { min(max(fraction, 0), 1) }

    public var body: some View {
        let fraction = Self.clamp(scrub ?? value)
        GeometryReader { proxy in
            let travel = max(proxy.size.width - Self.knob, 1)
            let x = Self.knob / 2 + travel * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(Deck.control).frame(height: 4)
                Capsule().fill(accent).frame(width: x, height: 4)
                Circle()
                    .fill(Deck.text)
                    .frame(width: Self.knob, height: Self.knob)
                    .overlay(Circle().stroke(Deck.secondary, lineWidth: 1.5).padding(-3).opacity(focused ? 1 : 0))
                    .offset(x: x - Self.knob / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in scrub = Self.clamp((drag.location.x - Self.knob / 2) / travel) }
                    .onEnded { drag in
                        commit(Self.clamp((drag.location.x - Self.knob / 2) / travel))
                        scrub = nil
                    },
                isEnabled: isEnabled)
        }
        .frame(height: 14)
        .animation(reduceMotion || scrub != nil ? nil : .linear(duration: 0.25), value: value)
        .opacity(isEnabled ? 1 : 0.4)
        .focusable(isEnabled)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { nudge(-step) }
        .onKeyPress(.rightArrow) { nudge(step) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spoken)
        .accessibilityAdjustableAction { direction in
            _ = nudge(direction == .increment ? step : -step)
        }
    }

    private func nudge(_ delta: Double) -> KeyPress.Result {
        guard isEnabled else { return .ignored }
        commit(Self.clamp(value + delta))
        return .handled
    }
}

// MARK: Popovers

/// How many popovers are open over the deck. A popover is a window of its own, so a click in it would
/// read as a click away from the deck and the pointer over it as leaving; while one is open the deck
/// treats both as still on the deck.
@MainActor
public enum DeckPopovers {
    public private(set) static var open = 0

    fileprivate static func opened() { open += 1 }
    fileprivate static func closed() { open = max(open - 1, 0) }
}

extension View {
    /// A popover below the view, dark like the deck, that keeps the deck open while it shows. Returns
    /// `AnyView`: SwiftUI's opaque popover type doesn't link from another module when built for macOS 14.
    public func deckPopover<Content: View>(
        isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content
    ) -> AnyView {
        AnyView(
            popover(isPresented: isPresented, arrowEdge: .bottom) {
                content()
                    .environment(\.colorScheme, .dark)
                    .onAppear { DeckPopovers.opened() }
                    .onDisappear { DeckPopovers.closed() }
            })
    }
}

/// The bar in Now's second row, 34 high: a request that needs you (amber outline on a warm black) or
/// the add field (a raised box). It fills the width it's given.
public struct DeckSlot<Content: View>: View {
    let needsYou: Bool
    let content: Content

    public init(needsYou: Bool = false, @ViewBuilder content: () -> Content) {
        self.needsYou = needsYou
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: needsYou ? 10 : 8) { content }
            .padding(.leading, needsYou ? 12 : 11)
            .padding(.trailing, needsYou ? 3 : 5)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(shape.fill(needsYou ? Deck.signalFill : Deck.cardRaised))
            .overlay(shape.strokeBorder(needsYou ? Deck.signal.opacity(0.55) : Deck.hairline, lineWidth: 1))
    }
}

/// A small value in the add field, such as the date it understood: 24 high, a 7 point radius.
public struct DeckValueChip: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .deckText(.figure)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Deck.control))
            .fixedSize()
    }
}

/// A running timer or Keep Awake beside the actions: a 26 high capsule with a figure, and an optional
/// icon before it.
public struct DeckStatusChip<Content: View>: View {
    let icon: DeckIcon?
    let content: Content

    public init(icon: DeckIcon? = nil, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 5) {
            if let icon { DeckIconView(icon, size: 12) }
            content.deckText(.figure).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(Deck.control))
        .fixedSize()
    }
}
