// SPDX-License-Identifier: MIT
import AppKit
import TopdeckCore

/// Sizes and placement of one display's notch surface. Measurements come from PUBLIC AppKit APIs
/// (safeAreaInsets, auxiliaryTop*Area): no private frameworks. The math is pure, so tests run it
/// against representative displays instead of whatever screens the build machine has.
struct NotchMetrics: Equatable {
    /// The display's frame in global coordinates.
    var screen: CGRect
    /// The physical notch, a stand-in drawn on a display without one, or nil for the floating pill.
    var notch: CGSize?
    /// Where the notch is centered: the middle of the gap, which can sit a hair off the display's
    /// center (half a point left on a 14" MacBook Pro), or the display's center without a notch.
    var centerX: CGFloat

    static let flare: CGFloat = 6  // the closed outline's flared top corners, which meet the screen edge
    static let shoulder: CGFloat = 18  // the open deck's concave top corners, outside its body on each side
    static let pill = CGSize(width: 180, height: 26)  // resting shape on a notchless display
    static let pillInset: CGFloat = 3  // gap above the floating pill
    static let hoverGrowth = CGSize(width: 12, height: 4)  // hover feedback
    static let dropTarget = CGSize(width: 300, height: 96)  // a file dragged near the closed notch
    static let closedPadding: CGFloat = 12  // at the outer end of a closed wing, and again beside the camera
    static let closedWingRange: ClosedRange<CGFloat> = 36...150  // how far a live activity reaches past either side
    static let closedSpacing: CGFloat = 6  // between a live activity's icon and its label
    static let overshootRoom: CGFloat = 1.08  // springy and jelly animations briefly overshoot

    /// The notch is the gap between the two auxiliary top areas; no insets means no notch, and then
    /// `standIn`, when given, is drawn in the middle of the top edge instead of the pill.
    init(screen: CGRect, safeAreaTop: CGFloat, left: CGRect?, right: CGRect?, standIn: CGSize? = nil) {
        self.screen = screen
        centerX = screen.midX
        notch = standIn
        if safeAreaTop > 0, let left, let right {
            notch = CGSize(width: max(0, right.minX - left.maxX), height: safeAreaTop)
            centerX = (left.maxX + right.minX) / 2
        }
    }

    init(screen: NSScreen, standIn: CGSize? = nil) {
        self.init(
            screen: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            left: screen.auxiliaryTopLeftArea,
            right: screen.auxiliaryTopRightArea,
            standIn: standIn
        )
    }

    /// A 14" MacBook Pro's notch is 185 pt wide: the stand-in's width when there's no real one to copy.
    static let standInWidth: CGFloat = 185
    /// macOS's menu bar on a display without a notch, when the display can't say (it hides it).
    static let menuBarHeight: CGFloat = 24

    /// The stand-in notch for a display without one: as wide as the Mac's own notch, or a
    /// MacBook's, and exactly as tall as the display's menu bar, so it sits inside the bar.
    static func standIn(on screen: NSScreen, among screens: [NSScreen]) -> CGSize {
        // Without a stand-in, a display's metrics hold only its real notch.
        let real = screens.lazy.compactMap { NotchMetrics(screen: $0).notch }.first
        let bar = screen.frame.maxY - screen.visibleFrame.maxY
        return CGSize(width: real?.width ?? standInWidth, height: bar > 0 ? bar : menuBarHeight)
    }

    /// The camera housing, or on a notchless display the pill that stands in for it.
    var housing: CGSize { notch ?? Self.pill }

    /// Resting shape: inside the camera housing, so a closed notch can't be seen. The gap between the
    /// auxiliary areas already includes the cutout's flared top corners (about 4 pt; its bottom
    /// corners are about 8 pt), so the outline's wider flare keeps its body inside the housing's
    /// sides, and it stops a point short of the housing's bottom edge. On notchless displays, a pill.
    var compactSize: CGSize {
        guard let notch else { return Self.pill }
        return CGSize(width: notch.width, height: notch.height - 1)
    }

    /// The open deck at the user's chosen body size, plus a shoulder on each side: never narrower than
    /// the camera housing plus room for the wings, never larger than the display allows.
    func expandedSize(_ chosen: CGSize) -> CGSize {
        let shoulders = notch == nil ? 0 : Self.shoulder * 2
        return CGSize(
            width: min(max(chosen.width, housing.width + 80), screen.width - 32 - shoulders) + shoulders,
            height: min(chosen.height, screen.height * 0.6))
    }

    /// The height of the top row, in line with the camera housing and never less than a navigation
    /// pill needs (a stand-in notch is only as tall as its menu bar).
    var topRowHeight: CGFloat { max(housing.height, 32) }

    func size(
        for presentation: NotchPresentationState, expanded: CGSize = NotchPreferences.defaultExpandedSize
    ) -> CGSize {
        switch presentation {
        case .hidden, .suspended, .compact:
            compactSize
        case .hoverArmed:
            CGSize(width: housing.width + Self.hoverGrowth.width, height: housing.height + Self.hoverGrowth.height)
        case .transient(let activity):
            closedSize(for: activity)
        case .dropTarget:
            CGSize(
                width: max(Self.dropTarget.width, housing.width + 2 * Self.closedPadding),
                height: Self.dropTarget.height
            )
        case .expanded, .pinned, .focused:
            expandedSize(expanded)
        }
    }

    /// The notch as `state` draws it: like `size(for:)`, but a resting notch with an ongoing activity
    /// grows its wings, and hovered it grows a little more.
    func size(for state: NotchState, expanded: CGSize = NotchPreferences.defaultExpandedSize) -> CGSize {
        guard let resting = state.restingActivity else { return size(for: state.presentation, expanded: expanded) }
        let growth = state.presentation == .hoverArmed ? Self.hoverGrowth : .zero
        let size = closedSize(for: resting)
        return CGSize(width: size.width + growth.width, height: size.height + growth.height)
    }

    /// A live activity's closed notch: at the camera's height, grown to each side by just what its
    /// leading and trailing content need. Inside a pill, one row as wide as both together.
    func closedSize(for activity: Activity) -> CGSize {
        let content = ClosedContent(activity)
        if notch == nil {
            let row = content.leadingWidth + content.trailingWidth + Self.closedPadding * 3
            let widest = housing.width + 2 * Self.closedWingRange.upperBound
            return CGSize(width: min(max(housing.width, row), widest), height: housing.height)
        }
        let wings = closedWings(for: content)
        return CGSize(width: housing.width + wings.leading + wings.trailing, height: housing.height)
    }

    /// How far a closed notch reaches past the camera housing on each side for `content`.
    func closedWings(for content: ClosedContent) -> (leading: CGFloat, trailing: CGFloat) {
        func wing(_ content: CGFloat) -> CGFloat {
            min(
                max(content + Self.closedPadding * 2 + Self.flare, Self.closedWingRange.lowerBound),
                Self.closedWingRange.upperBound)
        }
        return (wing(content.leadingWidth), wing(content.trailingWidth))
    }

    /// How far the shape sits right of center: half of how much farther its trailing wing reaches
    /// than its leading one, so the camera housing stays where it is. Zero without a notch.
    func offset(for state: NotchState) -> CGFloat {
        guard notch != nil else { return 0 }
        let activity: Activity?
        if case .transient(let shown) = state.presentation {
            activity = shown
        } else {
            activity = state.restingActivity
        }
        guard let activity else { return 0 }
        let wings = closedWings(for: ClosedContent(activity))
        return (wings.trailing - wings.leading) / 2
    }

    /// Gap between the top of the display and the shape: none on a notch, a little above a pill.
    var topInset: CGFloat { notch == nil ? Self.pillInset : 0 }

    /// Where the pointer counts as over a notch of `size` in `panel`, in screen coordinates. It
    /// reaches past the top of the display: a pointer pushed against the top edge sits at exactly the
    /// display's maxY, which a rect ending there doesn't contain. The gap above a pill counts too.
    func hoverFrame(for size: CGSize, in panel: CGRect) -> CGRect {
        CGRect(
            x: panel.midX - size.width / 2, y: panel.maxY - topInset - size.height,
            width: size.width, height: size.height + topInset + 1)
    }

    /// The fixed panel: big enough for every state at the largest size the notch can be resized to,
    /// with room for springy overshoot, pinned to the top and centered on the notch. The window never
    /// moves or resizes; only the shape inside it animates.
    var panelFrame: CGRect {
        let largest = [
            size(for: .hoverArmed),
            size(for: .dropTarget),
            // A live activity can reach out on one side, so the panel needs that much room on both.
            CGSize(width: housing.width + Self.closedWingRange.upperBound * 2, height: housing.height),
            size(for: .expanded(space: .now), expanded: NotchPreferences.maximumExpandedSize),
        ]
        let width = min(largest.map(\.width).max()! * Self.overshootRoom, screen.width)
        let height = min(largest.map(\.height).max()! * Self.overshootRoom + topInset, screen.height)
        return CGRect(x: centerX - width / 2, y: screen.maxY - height, width: width, height: height)
    }
}
