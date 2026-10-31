// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckCore

/// What the app plugs into every notch: feature views and actions the surface doesn't know about.
@MainActor
public struct NotchContent {
    /// A feature's view, for the space that shows it.
    public var feature: (FeatureID) -> AnyView
    /// What Now shows under its second row: its three columns.
    public var now: () -> AnyView
    /// The count on a space's label in its wing: agents waiting. Zero shows none.
    public var badge: (SpaceID) -> Int
    /// A space's own actions in the second row, before pin and Settings. The feature is the open detail screen, if any.
    public var actions: (SpaceID, FeatureID?) -> AnyView
    /// Files dropped on the notch; returns whether they were accepted.
    public var dropFiles: ([URL]) -> Bool
    public var openSettings: () -> Void
    /// A space that draws its whole body itself, from the features that are on: Tools. Nil for the
    /// others, which show their feature's view (or Now's columns).
    public var screen: (SpaceID, Set<FeatureID>) -> AnyView?
    /// What fills the middle of the second row of a space: on Now, the one slot between
    /// the clock and the actions.
    public var slot: (SpaceID) -> AnyView
    /// Joins a meeting from the closed notch's Join button.
    public var join: (URL) -> Void
    /// What stands at the left of the second row of a space, in place of its name: the
    /// Clipboard's filters, the Shelf's count. Nil keeps the name.
    public var leading: (SpaceID) -> AnyView?

    public init(
        feature: @escaping (FeatureID) -> AnyView,
        now: @escaping () -> AnyView,
        badge: @escaping (SpaceID) -> Int = { _ in 0 },
        actions: @escaping (SpaceID, FeatureID?) -> AnyView = { _, _ in AnyView(EmptyView()) },
        dropFiles: @escaping ([URL]) -> Bool,
        openSettings: @escaping () -> Void,
        screen: @escaping (SpaceID, Set<FeatureID>) -> AnyView? = { _, _ in nil },
        slot: @escaping (SpaceID) -> AnyView = { _ in AnyView(EmptyView()) },
        join: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        leading: @escaping (SpaceID) -> AnyView? = { _ in nil }
    ) {
        self.feature = feature
        self.now = now
        self.badge = badge
        self.actions = actions
        self.dropFiles = dropFiles
        self.openSettings = openSettings
        self.screen = screen
        self.slot = slot
        self.join = join
        self.leading = leading
    }
}

/// Horizontal and vertical scale for the squash-and-stretch animation styles.
struct Squash {
    var x: CGFloat = 1
    var y: CGFloat = 1
}

/// One display's notch. The panel around it never moves; this view animates one shape between
/// every presentation, so SwiftUI is the only animation owner.
struct NotchView: View {
    let engine: NotchEngine
    let metrics: NotchMetrics
    let preferences: NotchPreferences
    let content: NotchContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var dropTargeted = false
    @State private var justDropped = false

    var body: some View {
        let presentation = engine.state.presentation
        let resting = engine.state.restingActivity
        let size = metrics.size(for: engine.state, expanded: preferences.expandedSize)
        let outline = Self.shape(for: presentation, resting: resting != nil, on: metrics)
        ZStack(alignment: .top) {
            // Pure black, like the camera housing it opens from; an open deck fades to its body colour below it.
            if presentation.openSpace != nil {
                outline.fill(Deck.panelFill(height: size.height, notch: metrics.housing.height))
            } else {
                outline.fill(Deck.deck)
            }
            if let space = presentation.openSpace {
                DeckView(
                    engine: engine, metrics: metrics, preferences: preferences, content: content, space: space,
                    pinned: presentation.isPinned
                )
                .transition(.opacity)
            } else if case .transient(let activity) = presentation {
                ClosedNotchView(content: ClosedContent(activity), metrics: metrics, join: content.join)
                    .transition(.opacity)
            } else if presentation == .dropTarget {
                DropTargetView()
                    .transition(.opacity)
            } else if let resting {
                ClosedNotchView(content: ClosedContent(resting), metrics: metrics, join: content.join)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(outline)  // content fading between spaces never shows outside the notch
        .overlay {
            if contrast == .increased {
                outline.stroke(.white.opacity(0.45), lineWidth: 1)
            }
            if dropTargeted {
                outline.stroke(Color.accentColor, lineWidth: 2).shadow(color: .accentColor, radius: 6)
            }
        }
        .keyframeAnimator(initialValue: Squash(), trigger: presentation.openSpace != nil) { notch, squash in
            notch.scaleEffect(x: squash.x, y: squash.y, anchor: .top)  // anchored to the screen edge
        } keyframes: { _ in
            squashKeyframes(opening: presentation.openSpace != nil)
        }
        .environment(\.colorScheme, .dark)  // the notch is always black
        .gradientSymbols()
        .contentShape(outline)
        .onHover { engine.send($0 ? .pointerEntered : .pointerExited) }
        .onTapGesture { engine.send(.clicked) }
        .dropDestination(for: URL.self) { urls, _ in
            justDropped = true
            engine.send(.dropped)
            return content.dropFiles(urls)
        } isTargeted: { targeted in
            if targeted {
                justDropped = false
                engine.send(.dragEntered)
            } else if !justDropped {
                engine.send(.dragExited)
            }
            dropTargeted = targeted
        }
        // A live activity's wings reach out farther on one side; the camera housing stays where it is.
        .offset(x: metrics.offset(for: engine.state))
        .animation(motion(for: presentation), value: presentation)
        // Only an ongoing activity coming, going, or changing kind animates. A title updating in place,
        // like a speed every second, redraws once instead of running a spring each time.
        .animation(activityMotion, value: resting.map { [$0.feature?.rawValue, $0.symbol] })
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.8), value: dropTargeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Topdeck")
        .accessibilityAction(named: presentation.openSpace == nil ? "Open" : "Close") {
            engine.send(presentation.openSpace == nil ? .clicked : .dismiss)
        }
        .padding(.top, metrics.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// `resting` is a resting notch showing an ongoing activity, which takes a live activity's shape.
    static func shape(for presentation: NotchPresentationState, resting: Bool = false, on metrics: NotchMetrics)
        -> NotchShape
    {
        let open = presentation.openSpace != nil
        guard metrics.notch != nil else {
            let radius = open ? Deck.Radius.deck : presentation == .dropTarget ? Self.dropRadius : Self.pillRadius
            return NotchShape(topRadius: 0, bottomRadius: radius, flushTop: false)
        }
        switch presentation {
        case .expanded, .pinned, .focused:
            // Concave shoulders into the screen's edge, and the deck's bottom corners.
            return NotchShape(topRadius: NotchMetrics.shoulder, bottomRadius: Deck.Radius.deck)
        case .dropTarget: return NotchShape(topRadius: NotchMetrics.flare, bottomRadius: Self.dropRadius)
        case .hoverArmed, .transient: return NotchShape(topRadius: NotchMetrics.flare, bottomRadius: Self.closedRadius)
        case .compact where resting: return NotchShape(topRadius: NotchMetrics.flare, bottomRadius: Self.closedRadius)
        // Closed: rounder than the housing's own corners, so the shape stays hidden behind it.
        default: return NotchShape(topRadius: NotchMetrics.flare, bottomRadius: 10)
        }
    }

    private static let pillRadius: CGFloat = 100  // clamped to a capsule
    private static let closedRadius: CGFloat = 14  // a live activity's bottom corners, as on the Closed board
    private static let dropRadius: CGFloat = 22  // the drop target's

    /// Live activities, one-shot or ongoing, come and go on their own spring.
    private var activityMotion: Animation? {
        if reduceMotion { return .easeInOut(duration: 0.12) }
        return preferences.animationStyle == .instant ? nil : .spring(response: 0.3, dampingFraction: 0.85)
    }

    /// Opening and closing in the user's chosen style. Hover only nudges and live activities keep
    /// their own spring; Reduce Motion swaps everything for a short ease.
    private func motion(for presentation: NotchPresentationState) -> Animation? {
        if reduceMotion { return .easeInOut(duration: 0.12) }
        let style = preferences.animationStyle
        switch presentation {
        case .hoverArmed: return style == .instant ? nil : .easeOut(duration: 0.12)
        case .transient, .dropTarget: return activityMotion
        default: break
        }
        let opening = presentation.openSpace != nil
        switch style {
        case .spring:
            return opening
                ? .spring(response: 0.32, dampingFraction: 0.78) : .spring(response: 0.24, dampingFraction: 0.95)
        case .jelly:
            return opening
                ? .spring(response: 0.5, dampingFraction: 0.55) : .spring(response: 0.38, dampingFraction: 0.66)
        case .pop:
            return opening
                ? .spring(response: 0.3, dampingFraction: 0.6) : .spring(response: 0.22, dampingFraction: 0.82)
        case .smooth: return .easeInOut(duration: opening ? 0.34 : 0.26)
        case .snappy: return .snappy(duration: opening ? 0.2 : 0.15)
        case .instant: return nil
        }
    }

    /// Squash-and-stretch beats layered on the size change. Jelly squashes wide, stretches down, and
    /// wobbles into place; Pop springs up from slightly smaller. Other styles hold still.
    @KeyframesBuilder<Squash>
    private func squashKeyframes(opening: Bool) -> some Keyframes<Squash> {
        let style = reduceMotion ? NotchAnimationStyle.smooth : preferences.animationStyle
        let (x, y): ([CGFloat], [CGFloat]) =
            switch (style, opening) {
            case (.jelly, true): ([1, 1.06, 0.97, 1.01], [1, 0.9, 1.04, 0.99])
            case (.jelly, false): ([1, 1.04, 0.98, 1], [1, 0.94, 1.02, 1])
            case (.pop, true): ([0.92, 1.03, 0.995, 1], [0.92, 1.03, 0.995, 1])
            case (.pop, false): ([1, 0.96, 1.01, 1], [1, 0.96, 1.01, 1])
            default: ([1, 1, 1, 1], [1, 1, 1, 1])
            }
        KeyframeTrack(\.x) {
            MoveKeyframe(x[0])
            SpringKeyframe(x[1], duration: 0.12)
            SpringKeyframe(x[2], duration: 0.16)
            SpringKeyframe(x[3], duration: 0.14)
            SpringKeyframe(1, duration: 0.2)
        }
        KeyframeTrack(\.y) {
            MoveKeyframe(y[0])
            SpringKeyframe(y[1], duration: 0.12)
            SpringKeyframe(y[2], duration: 0.16)
            SpringKeyframe(y[3], duration: 0.14)
            SpringKeyframe(1, duration: 0.2)
        }
    }
}

extension View {
    /// SF Symbols 7's gradient rendering, which shades each symbol from its one color like the rest
    /// of macOS 26's Liquid Glass. Drawn once, it costs nothing after.
    @ViewBuilder fileprivate func gradientSymbols() -> some View {
        if #available(macOS 26, *) {
            symbolColorRenderingMode(.gradient)
        } else {
            self
        }
    }
}
