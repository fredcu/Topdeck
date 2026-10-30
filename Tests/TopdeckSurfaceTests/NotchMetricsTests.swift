// SPDX-License-Identifier: MIT
import AppKit
import CoreGraphics
import SwiftUI
import Testing
import TopdeckCore

@testable import TopdeckSurface

/// As measured on hardware: the gap sits half a point left of the display's center.
private let macBookPro14 = NotchMetrics(
    screen: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
    left: CGRect(x: 0, y: 950, width: 663, height: 32), right: CGRect(x: 848, y: 950, width: 664, height: 32))
private let macBookPro16 = NotchMetrics(
    screen: CGRect(x: 0, y: 0, width: 1728, height: 1117), safeAreaTop: 38,
    left: CGRect(x: 0, y: 1079, width: 764, height: 38), right: CGRect(x: 964, y: 1079, width: 764, height: 38))
/// A notchless external display to the left of the built-in one.
private let external = NotchMetrics(
    screen: CGRect(x: -2560, y: 180, width: 2560, height: 1440), safeAreaTop: 0, left: nil, right: nil)
/// The same display with a notch drawn in its 24 pt menu bar, as wide as the MacBook's.
private let externalWithNotch = NotchMetrics(
    screen: CGRect(x: -2560, y: 180, width: 2560, height: 1440), safeAreaTop: 0, left: nil, right: nil,
    standIn: CGSize(width: 185, height: 24))

private let song = Activity(feature: .media, symbol: "music.note", title: "Song", duration: .seconds(2))
private let volume = Activity(
    feature: nil, symbol: "speaker.wave.2.fill", title: "50%", level: 0.5, duration: .seconds(1))
private let meeting = Activity(
    feature: .calendar, symbol: "video.fill", title: "Standup", duration: .zero,
    countdown: Date(timeIntervalSince1970: 1_790_000_000))
private let waiting = Activity(feature: .agents, symbol: "hand.raised.fill", title: "2 waiting", duration: .zero)

struct NotchMetricsTests {
    static let displays = [macBookPro14, macBookPro16, external, externalWithNotch]
    static let presentations: [NotchPresentationState] = [
        .compact, .hoverArmed, .transient(song), .transient(volume), .transient(meeting), .dropTarget,
        .expanded(space: .now), .pinned(space: .stash), .focused(space: .stash, pinned: false),
    ]

    @Test(arguments: displays)
    func thePanelIsPinnedToTheTopAndCenteredOnTheNotch(metrics: NotchMetrics) {
        let panel = metrics.panelFrame
        #expect(abs(panel.midX - metrics.centerX) < 0.001)
        #expect(abs(panel.maxY - metrics.screen.maxY) < 0.5)
        #expect(metrics.screen.contains(panel))
    }

    /// The Closed board: every live activity is one row at the camera's height, never under it.
    @Test(arguments: displays)
    func everyLiveActivityIsOneRowAtTheCamerasHeight(metrics: NotchMetrics) {
        for activity in [song, volume, meeting, waiting] {
            #expect(metrics.size(for: .transient(activity)).height == metrics.housing.height, "\(activity.title)")
        }
    }

    @Test func theWingsGrowOnlyAsFarAsEachSideNeeds() {
        let metrics = macBookPro14
        let housing = metrics.housing.width
        let playing = metrics.closedWings(for: ClosedContent(song))
        let level = metrics.closedWings(for: ClosedContent(volume))
        let flare = NotchMetrics.flare
        // A symbol and a level: the icon on the left, the 92 point meter on the right, 12 point margins.
        #expect(level.leading == 16 + 24 + flare && level.trailing == ClosedContent.meterWidth + 24 + flare)
        #expect(level.trailing > level.leading, "the meter's side reaches farther")
        #expect(metrics.size(for: .transient(volume)).width == housing + level.leading + level.trailing)
        // What isn't needed isn't drawn: a label only, with nothing on the right, keeps a short stub.
        #expect(playing.trailing == NotchMetrics.closedWingRange.lowerBound)
        #expect(metrics.size(for: .transient(song)).width < metrics.size(for: .transient(volume)).width)
    }

    @Test(arguments: displays)
    func aLongLabelStopsAtTheCeiling(metrics: NotchMetrics) {
        let title = String(repeating: "A very long video title ", count: 4)
        let long = Activity(feature: .shelf, symbol: "tray.full", title: title, duration: .zero)
        let size = metrics.size(for: .transient(long))
        #expect(size.width <= metrics.housing.width + 2 * NotchMetrics.closedWingRange.upperBound)
        #expect(size.width <= metrics.panelFrame.width && size.height == metrics.housing.height)
        #expect(metrics.size(for: .transient(song)).width < size.width, "a short one is narrower")
    }

    @Test(arguments: displays)
    func anOngoingActivityRestsInWingsAroundTheCamera(metrics: NotchMetrics) {
        var state = NotchState()
        _ = state.handle(.show)
        _ = state.handle(.setOngoing(waiting))
        let resting = metrics.size(for: state)
        let housing = metrics.housing
        #expect(resting.height == housing.height, "in the menu bar, never over windows")
        if metrics.notch != nil {
            let content = ClosedContent(waiting)
            let wings = metrics.closedWings(for: content)
            #expect(resting.width == housing.width + wings.leading + wings.trailing)
            // The shape moves right by half of how much farther its right wing reaches, so the camera
            // housing stays where it is.
            let offset = metrics.offset(for: state)
            #expect(offset == (wings.trailing - wings.leading) / 2)
            let frame = metrics.hoverFrame(for: resting, in: metrics.panelFrame).offsetBy(dx: offset, dy: 0)
            #expect(abs(frame.minX + wings.leading - (metrics.centerX - housing.width / 2)) < 0.001)
            #expect(frame.minX >= metrics.panelFrame.minX && frame.maxX <= metrics.panelFrame.maxX)
        } else {
            #expect(metrics.offset(for: state) == 0, "inside the pill, centered")
        }
        // Hovered, it grows a little instead of shrinking to the plain hover shape, so the pointer on
        // the wing stays on the notch while it waits to open.
        var hovered = state
        _ = hovered.handle(.pointerEntered)
        let grown = metrics.size(for: hovered)
        #expect(grown.width == resting.width + NotchMetrics.hoverGrowth.width && grown.height > resting.height)
        #expect(metrics.offset(for: hovered) == metrics.offset(for: state))
        _ = state.handle(.clicked)
        #expect(metrics.size(for: state) == metrics.size(for: .expanded(space: .agents)), "open, it's the deck")
        #expect(metrics.offset(for: state) == 0, "and centered again")
    }

    @Test func aCountdownMakesRoomForItsLongestReading() {
        func wing(_ seconds: TimeInterval) -> CGFloat {
            let countdown = Activity(
                feature: .calendar, symbol: "video.fill", title: "Standup", duration: .zero,
                countdown: Date.now + seconds)
            return ClosedContent(countdown).trailingWidth
        }
        #expect(wing(300) < wing(2 * 3600 + 60), "hours need more room than minutes")
    }

    @Test @MainActor func aFileDraggedNearIsADropTargetUnderTheCamera() {
        let target = macBookPro14.size(for: .dropTarget)
        #expect(target == CGSize(width: 300, height: 96), "as on the Closed board")
        #expect(external.size(for: .dropTarget).height == 96)
        #expect(NotchView.shape(for: .dropTarget, on: macBookPro14).bottomRadius == 22)
    }

    @Test(arguments: displays)
    func aPointerPushedAgainstTheTopEdgeIsOverTheNotch(metrics: NotchMetrics) {
        let compact = metrics.size(for: .compact)
        let frame = metrics.hoverFrame(for: compact, in: metrics.panelFrame)
        #expect(frame.contains(CGPoint(x: metrics.centerX, y: metrics.screen.maxY)), "the top edge is exactly maxY")
        let below = metrics.screen.maxY - metrics.topInset - compact.height - 0.5
        #expect(!frame.contains(CGPoint(x: metrics.centerX, y: below)), "below the notch is not over it")
    }

    @Test(arguments: displays, presentations)
    func everyStateFitsInsideTheFixedPanel(metrics: NotchMetrics, presentation: NotchPresentationState) {
        let size = metrics.size(for: presentation)
        #expect(size.width <= metrics.panelFrame.width)
        #expect(size.height + metrics.topInset <= metrics.panelFrame.height)
    }

    @Test(arguments: displays)
    func statesGrowInTheRightOrder(metrics: NotchMetrics) {
        let compact = metrics.size(for: .compact)
        let hover = metrics.size(for: .hoverArmed)
        let live = metrics.size(for: .transient(volume))
        let open = metrics.size(for: .expanded(space: .now))
        let housing = metrics.housing
        #expect(compact.width <= housing.width && compact.height <= housing.height)
        #expect(hover.width > housing.width && hover.height > housing.height, "hover shows past the housing")
        if metrics.notch != nil {
            #expect(live.width > housing.width && live.height >= housing.height, "an activity's wings show beside it")
        }
        #expect(open.width > live.width && open.height > live.height)
    }

    /// The housing as measured on hardware: the gap between the auxiliary areas, with top corners
    /// that flare about 4 pt and bottom corners of about 8 pt when it's 32 pt tall.
    @Test(arguments: [macBookPro14, macBookPro16]) @MainActor
    func aClosedNotchHidesBehindTheCameraHousing(metrics: NotchMetrics) throws {
        let notch = try #require(metrics.notch)
        let housing = NotchShape(topRadius: notch.height / 8, bottomRadius: notch.height / 4)
            .path(in: CGRect(origin: .zero, size: notch))
        let size = metrics.size(for: .compact)
        let resting = NotchView.shape(for: .compact, on: metrics)
            .path(in: CGRect(x: (notch.width - size.width) / 2, y: 0, width: size.width, height: size.height))
        // Every Retina pixel the closed notch covers, around and under the housing, must be hidden.
        var showing: [CGPoint] = []
        for x in stride(from: -19.75, to: notch.width + 20, by: 0.5) {
            for y in stride(from: 0.25, to: notch.height + 10, by: 0.5) {
                let pixel = CGPoint(x: x, y: y)
                if resting.contains(pixel), !housing.contains(pixel) { showing.append(pixel) }
            }
        }
        #expect(showing.isEmpty, "shows past the housing at \(showing.prefix(4))")
        #expect(resting.contains(CGPoint(x: notch.width / 2, y: 1)), "and it's still there to hover over")
    }

    @Test(arguments: displays)
    func everyResizeFitsInsideTheFixedPanel(metrics: NotchMetrics) {
        for chosen in [NotchPreferences.minimumExpandedSize, NotchPreferences.maximumExpandedSize] {
            let size = metrics.size(for: .expanded(space: .now), expanded: chosen)
            let panel = metrics.panelFrame
            #expect(size.width <= panel.width && size.height + metrics.topInset <= panel.height)
        }
    }

    @Test func theChosenSizeIsTheDecksBodyAndTheShouldersComeOnTopOfIt() {
        let shoulders = 2 * NotchMetrics.shoulder
        #expect(
            macBookPro14.size(for: .pinned(space: .stash), expanded: CGSize(width: 700, height: 430)).width == 700
                + shoulders)
        #expect(macBookPro14.size(for: .expanded(space: .now)).height == 430, "700 by 430 to begin with")
        #expect(external.size(for: .expanded(space: .now)).width == 700, "a floating pill has no shoulders")
        let tiny = macBookPro14.size(for: .expanded(space: .now), expanded: CGSize(width: 100, height: 300))
        #expect(tiny.width == macBookPro14.housing.width + 80 + shoulders)
    }

    @Test func theTopRowIsAsTallAsTheCameraButNeverTooShortForAPill() {
        #expect(macBookPro14.topRowHeight == 32 && macBookPro16.topRowHeight == 38)
        #expect(externalWithNotch.topRowHeight == 32, "a 24 point menu bar still fits a 27 point pill")
    }

    @Test func theNotchIsTheGapBetweenTheAuxiliaryAreas() {
        #expect(macBookPro14.notch == CGSize(width: 185, height: 32))
        #expect(macBookPro14.centerX == 755.5, "half a point left of the display's center")
        #expect(external.centerX == external.screen.midX)
        #expect(macBookPro14.topInset == 0)
    }

    @Test func notchlessDisplaysGetAFloatingPill() {
        #expect(external.notch == nil)
        #expect(external.size(for: .compact) == NotchMetrics.pill)
        #expect(external.topInset == NotchMetrics.pillInset)
    }

    @Test func aDisplayWithoutANotchCanHaveOneDrawnInsideItsMenuBar() {
        #expect(externalWithNotch.notch == CGSize(width: 185, height: 24))
        #expect(externalWithNotch.topInset == 0, "flush with the top edge, like a real one")
        #expect(externalWithNotch.size(for: .compact) == CGSize(width: 185, height: 23), "inside the menu bar")
        #expect(externalWithNotch.centerX == externalWithNotch.screen.midX)
        let real = NotchMetrics(
            screen: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
            left: CGRect(x: 0, y: 950, width: 663, height: 32), right: CGRect(x: 848, y: 950, width: 664, height: 32),
            standIn: CGSize(width: 100, height: 20))
        #expect(real.notch == CGSize(width: 185, height: 32), "a real notch wins over a stand-in")
    }

    @Test func insetsWithoutAuxiliaryAreasAreNotANotch() {
        let metrics = NotchMetrics(
            screen: CGRect(x: 0, y: 0, width: 1440, height: 900), safeAreaTop: 24, left: nil, right: nil)
        #expect(metrics.notch == nil)
    }
}

struct NotchShapeTests {
    private let rect = CGRect(x: 0, y: 0, width: 200, height: 40)

    @Test func theDecksShouldersAreConcaveAndItsBottomCornersAre30() {
        let rect = CGRect(x: 0, y: 0, width: 736, height: 430)
        let path = NotchShape(topRadius: NotchMetrics.shoulder, bottomRadius: Deck.Radius.deck).path(in: rect)
        #expect(path.contains(CGPoint(x: 10, y: 0.5)), "the shoulder flares out along the top edge")
        #expect(!path.contains(CGPoint(x: 5, y: 12)), "and the body's side is inset by the shoulder")
        #expect(path.contains(CGPoint(x: 18.5, y: 215)))
        #expect(!path.contains(CGPoint(x: 18.5 + 2, y: 429)), "the bottom corner is rounded")
    }

    @Test func theNotchOutlineIsFlushWithTheTopAndRoundedBelow() {
        let path = NotchShape(topRadius: 6, bottomRadius: 10).path(in: rect)
        let bounds = path.boundingRect
        #expect(abs(bounds.minY) < 0.01 && abs(bounds.maxY - 40) < 0.01)
        #expect(abs(bounds.minX) < 0.01 && abs(bounds.maxX - 200) < 0.01)
        #expect(path.contains(CGPoint(x: 4, y: 0.5)), "top corners flare out along the top edge")
        #expect(!path.contains(CGPoint(x: 1, y: 20)), "below the flare the sides are inset")
        #expect(!path.contains(CGPoint(x: 7, y: 39.5)), "bottom corners are rounded")
        #expect(path.contains(CGPoint(x: 100, y: 20)))
    }

    @Test func aFloatingOutlineIsACapsule() {
        let path = NotchShape(topRadius: 0, bottomRadius: 100, flushTop: false).path(in: rect)
        #expect(path.contains(CGPoint(x: 100, y: 20)))
        #expect(!path.contains(CGPoint(x: 1, y: 1)), "no square corners")
    }
}
