// SPDX-License-Identifier: MIT
import CoreGraphics
import Foundation
import Testing

@testable import TopdeckFeatures

/// Screens of three shapes, as visible frames in AppKit coordinates.
private enum Screens {
    /// A laptop: menu bar above, Dock below.
    static let landscape = CGRect(x: 0, y: 75, width: 1440, height: 800)
    /// A portrait display to the right of it, lower down.
    static let portrait = CGRect(x: 1440, y: -500, width: 1080, height: 1920)
    /// An ultrawide whose thirds don't come out whole.
    static let ultrawide = CGRect(x: 0, y: 0, width: 3440, height: 1400)
}

private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: width, height: height)
}

private func frame(_ action: WindowAction, _ screen: CGRect, window: CGRect? = nil, gap: CGFloat = 0) -> CGRect? {
    WindowFrames.frame(for: action, window: window, in: screen, gap: gap)
}

struct WindowFrameTests {
    @Test func halvesSplitALandscapeScreen() {
        let screen = Screens.landscape
        #expect(frame(.leftHalf, screen) == rect(0, 75, 720, 800))
        #expect(frame(.rightHalf, screen) == rect(720, 75, 720, 800))
        #expect(frame(.topHalf, screen) == rect(0, 475, 1440, 400))
        #expect(frame(.bottomHalf, screen) == rect(0, 75, 1440, 400))
    }

    @Test func halvesSplitAPortraitScreenTheSameWay() {
        let screen = Screens.portrait
        #expect(frame(.leftHalf, screen) == rect(1440, -500, 540, 1920))
        #expect(frame(.rightHalf, screen) == rect(1980, -500, 540, 1920))
        #expect(frame(.topHalf, screen) == rect(1440, 460, 1080, 960))
        #expect(frame(.bottomHalf, screen) == rect(1440, -500, 1080, 960))
    }

    @Test func quartersAreTheCorners() {
        let screen = Screens.landscape
        #expect(frame(.topLeft, screen) == rect(0, 475, 720, 400))
        #expect(frame(.topRight, screen) == rect(720, 475, 720, 400))
        #expect(frame(.bottomLeft, screen) == rect(0, 75, 720, 400))
        #expect(frame(.bottomRight, screen) == rect(720, 75, 720, 400))
        #expect(frame(.topLeft, Screens.portrait) == rect(1440, 460, 540, 960))
        #expect(frame(.bottomRight, Screens.ultrawide) == rect(1720, 0, 1720, 700))
    }

    @Test func thirdsAreColumnsOnALandscapeScreen() {
        let screen = Screens.landscape
        #expect(frame(.firstThird, screen) == rect(0, 75, 480, 800))
        #expect(frame(.centerThird, screen) == rect(480, 75, 480, 800))
        #expect(frame(.lastThird, screen) == rect(960, 75, 480, 800))
        #expect(frame(.firstTwoThirds, screen) == rect(0, 75, 960, 800))
        #expect(frame(.lastTwoThirds, screen) == rect(480, 75, 960, 800))
    }

    @Test func thirdsAreRowsFromTheTopOnAPortraitScreen() {
        let screen = Screens.portrait
        #expect(frame(.firstThird, screen) == rect(1440, 780, 1080, 640))
        #expect(frame(.centerThird, screen) == rect(1440, 140, 1080, 640))
        #expect(frame(.lastThird, screen) == rect(1440, -500, 1080, 640))
        #expect(frame(.firstTwoThirds, screen) == rect(1440, 140, 1080, 1280))
        #expect(frame(.lastTwoThirds, screen) == rect(1440, -500, 1080, 1280))
    }

    @Test func unevenThirdsRoundDownAndTheLastOneMeetsTheEdge() {
        let screen = Screens.ultrawide
        #expect(frame(.firstThird, screen) == rect(0, 0, 1146, 1400))
        #expect(frame(.centerThird, screen) == rect(1146, 0, 1146, 1400))
        #expect(frame(.lastThird, screen) == rect(2294, 0, 1146, 1400))
        #expect(frame(.firstTwoThirds, screen) == rect(0, 0, 2293, 1400))
        #expect(frame(.lastTwoThirds, screen) == rect(1147, 0, 2293, 1400))
        #expect(frame(.leftHalf, screen) == rect(0, 0, 1720, 1400))
        #expect(frame(.topHalf, screen) == rect(0, 700, 3440, 700))
    }

    @Test func maximizeFillsTheVisibleFrameAndAlmostMaximizeLeavesATenthAround() {
        #expect(frame(.maximize, Screens.landscape) == Screens.landscape)
        #expect(frame(.maximize, Screens.portrait) == Screens.portrait)
        #expect(frame(.almostMaximize, Screens.landscape) == rect(72, 115, 1296, 720))
        #expect(frame(.almostMaximize, Screens.portrait) == rect(1494, -404, 972, 1728))
        #expect(frame(.almostMaximize, Screens.ultrawide) == rect(172, 70, 3096, 1260))
    }

    @Test func nextDisplayNeedsTheOtherScreens() {
        #expect(frame(.nextDisplay, Screens.landscape) == nil)
    }

    @Test func repeatingAHalfStepsThroughTwoThirdsAndOneThird() {
        let screen = Screens.landscape
        let half = rect(0, 75, 720, 800)
        let twoThirds = rect(0, 75, 960, 800)
        let third = rect(0, 75, 480, 800)
        #expect(frame(.leftHalf, screen, window: rect(100, 100, 500, 500)) == half)
        #expect(frame(.leftHalf, screen, window: half) == twoThirds)
        #expect(frame(.leftHalf, screen, window: twoThirds) == third)
        #expect(frame(.leftHalf, screen, window: third) == half)
        #expect(frame(.rightHalf, screen, window: rect(720, 75, 720, 800)) == rect(480, 75, 960, 800))
        #expect(frame(.leftHalf, screen, window: rect(1, 76, 719, 799)) == twoThirds, "a point off still counts")
        #expect(frame(.topLeft, screen, window: rect(0, 475, 720, 400)) == rect(0, 475, 960, 400))
        #expect(frame(.topHalf, screen, window: rect(0, 475, 1440, 400)) == rect(0, 475, 1440, 400))
    }

    @Test func repeatingAThirdMovesAlong() {
        let screen = Screens.landscape
        let first = rect(0, 75, 480, 800)
        let center = rect(480, 75, 480, 800)
        let last = rect(960, 75, 480, 800)
        #expect(frame(.firstThird, screen, window: first) == center)
        #expect(frame(.firstThird, screen, window: center) == last)
        #expect(frame(.firstThird, screen, window: last) == first)
        #expect(frame(.lastThird, screen, window: last) == center)
        #expect(frame(.centerThird, screen, window: center) == center)
        #expect(frame(.firstTwoThirds, screen, window: rect(0, 75, 960, 800)) == rect(480, 75, 960, 800))
        #expect(frame(.lastTwoThirds, screen, window: rect(480, 75, 960, 800)) == rect(0, 75, 960, 800))
    }

    @Test func gapsGoAroundTheEdgesAndHalfOfOneBetweenWindows() {
        let screen = Screens.landscape
        #expect(frame(.leftHalf, screen, gap: 10) == rect(10, 85, 705, 780))
        #expect(frame(.rightHalf, screen, gap: 10) == rect(725, 85, 705, 780))
        #expect(frame(.topRight, screen, gap: 10) == rect(725, 480, 705, 385))
        #expect(frame(.centerThird, screen, gap: 10) == rect(485, 85, 470, 780))
        #expect(frame(.maximize, screen, gap: 10) == rect(10, 85, 1420, 780))
        #expect(frame(.almostMaximize, screen, gap: 10) == rect(72, 115, 1296, 720), "it has its own margin")
        #expect(frame(.leftHalf, screen, window: rect(10, 85, 705, 780), gap: 10) == rect(10, 85, 945, 780))
    }
}

struct DisplayTests {
    private let screens = [rect(0, 0, 1440, 900), rect(1440, -500, 1080, 1920), rect(-1920, 0, 1920, 1080)]

    @Test func aWindowBelongsToTheScreenShowingMostOfIt() {
        #expect(WindowFrames.screen(for: rect(100, 100, 400, 300), in: screens) == 0)
        #expect(WindowFrames.screen(for: rect(1300, 100, 400, 300), in: screens) == 1)
        #expect(WindowFrames.screen(for: rect(-300, 100, 400, 300), in: screens) == 2)
        #expect(WindowFrames.screen(for: rect(5000, 400, 10, 10), in: screens) == 1, "off every screen: the nearest")
        #expect(WindowFrames.screen(for: rect(0, 0, 10, 10), in: []) == nil)
    }

    @Test func nextDisplayGoesLeftToRightAndRoundAgain() {
        #expect(WindowFrames.nextScreen(after: 2, in: screens) == 0)
        #expect(WindowFrames.nextScreen(after: 0, in: screens) == 1)
        #expect(WindowFrames.nextScreen(after: 1, in: screens) == 2)
        #expect(WindowFrames.nextScreen(after: 0, in: [screens[0]]) == nil)
        let stacked = [rect(0, 0, 1440, 900), rect(0, 900, 1920, 1080)]
        #expect(WindowFrames.nextScreen(after: 1, in: stacked) == 0, "the upper one first")
    }

    @Test func aWindowKeepsItsShareOfTheScreenOnTheNext() {
        let moved = WindowFrames.moved(rect(360, 275, 720, 400), from: Screens.landscape, to: Screens.portrait)
        #expect(moved == rect(1710, -20, 540, 960))
        let half = WindowFrames.moved(rect(0, 75, 720, 800), from: Screens.landscape, to: Screens.portrait)
        #expect(half == rect(1440, -500, 540, 1920))
    }

    @Test func aMaximizedWindowStaysMaximized() {
        let maximized = WindowFrames.moved(Screens.landscape, from: Screens.landscape, to: Screens.ultrawide)
        #expect(maximized == Screens.ultrawide)
        let gapped = rect(10, 85, 1420, 780)
        let moved = WindowFrames.moved(gapped, from: Screens.landscape, to: Screens.portrait, gap: 10)
        #expect(moved == rect(1450, -490, 1060, 1900))
    }

    @Test func aWindowPartlyOffItsScreenLandsInsideTheNext() {
        let moved = WindowFrames.moved(rect(1000, 75, 720, 800), from: Screens.landscape, to: Screens.portrait)
        #expect(moved == rect(1980, -500, 540, 1920))
    }

    @Test func accessibilityCoordinatesFlipAgainstThePrimaryDisplay() {
        let flipped = WindowFrames.flipped(rect(0, 75, 720, 800), primaryHeight: 900)
        #expect(flipped == rect(0, 25, 720, 800))
        #expect(WindowFrames.flipped(flipped, primaryHeight: 900) == rect(0, 75, 720, 800))
        #expect(WindowFrames.flipped(rect(1440, -500, 1080, 1920), primaryHeight: 900) == rect(1440, -520, 1080, 1920))
    }
}

struct SnapAreaTests {
    private let screen = rect(0, 0, 1440, 900)
    private let portrait = rect(1440, -500, 1080, 1920)

    private func action(_ x: CGFloat, _ y: CGFloat, on frame: CGRect, prior: WindowAction? = nil) -> WindowAction? {
        SnapAreas.action(at: CGPoint(x: x, y: y), in: frame, prior: prior)
    }

    @Test func cornersTakeQuartersAndTheTopMaximizes() {
        #expect(action(2, 899, on: screen) == .topLeft)
        #expect(action(1440, 900, on: screen) == .topRight)
        #expect(action(0, 0, on: screen) == .bottomLeft)
        #expect(action(1439, 3, on: screen) == .bottomRight)
        #expect(action(720, 899, on: screen) == .maximize)
        #expect(action(720, 450, on: screen) == nil)
        #expect(action(2000, 2, on: screen) == nil, "another screen's")
    }

    @Test func sidesTakeHalvesAndTheirEndsTopOrBottomHalves() {
        #expect(action(2, 450, on: screen) == .leftHalf)
        #expect(action(1438, 450, on: screen) == .rightHalf)
        #expect(action(2, 100, on: screen) == .bottomHalf)
        #expect(action(1438, 800, on: screen) == .topHalf)
    }

    @Test func theBottomTakesThirdsAndWidensToTwoThirdsFromASide() {
        #expect(action(100, 2, on: screen) == .firstThird)
        #expect(action(720, 2, on: screen) == .centerThird)
        #expect(action(1300, 2, on: screen) == .lastThird)
        #expect(action(720, 2, on: screen, prior: .firstThird) == .firstTwoThirds)
        #expect(action(720, 2, on: screen, prior: .lastThird) == .lastTwoThirds)
        #expect(action(720, 2, on: screen, prior: .lastTwoThirds) == .lastTwoThirds)
    }

    @Test func aPortraitScreenSwapsThirdsAndHalves() {
        #expect(action(1700, -498, on: portrait) == .leftHalf)
        #expect(action(2200, -498, on: portrait) == .rightHalf)
        #expect(action(1442, 1000, on: portrait) == .firstThird)
        #expect(action(1442, 460, on: portrait) == .centerThird)
        #expect(action(2518, -200, on: portrait) == .lastThird)
        #expect(action(1442, 460, on: portrait, prior: .firstThird) == .firstTwoThirds)
        #expect(action(1442, 1300, on: portrait) == .topHalf)
        #expect(action(1980, 1419, on: portrait) == .maximize)
    }

    @Test func everySnapAreaHasAFrame() {
        for point in [CGPoint(x: 2, y: 899), CGPoint(x: 720, y: 899), CGPoint(x: 2, y: 450), CGPoint(x: 720, y: 2)] {
            let snapped = SnapAreas.action(at: point, in: screen)
            #expect(snapped.flatMap { frame($0, Screens.landscape) } != nil)
        }
    }
}

struct WindowLayoutTests {
    private let layout = WindowLayout(
        name: "Writing",
        placements: [
            .init(app: "com.example.editor", title: "Doc 1", display: "A", frame: rect(0, 0, 0.5, 1)),
            .init(app: "com.example.editor", title: "Doc 2", display: "A", frame: rect(0.5, 0, 0.5, 1)),
            .init(app: "com.example.browser", title: "Docs", display: "B", frame: rect(0, 0, 1, 1)),
        ])

    @Test func windowsMatchByTitleThenInOrder() {
        let windows = [
            WindowLayout.Window(app: "com.example.editor", title: "Doc 2"),
            WindowLayout.Window(app: "com.example.editor", title: "Untitled"),
            WindowLayout.Window(app: "com.example.browser", title: "News"),
            WindowLayout.Window(app: "com.example.mail", title: "Inbox"),
            WindowLayout.Window(app: "com.example.editor", title: "Doc 3"),
        ]
        let assignments = layout.assignments(for: windows)
        #expect(assignments[0]?.title == "Doc 2")
        #expect(assignments[1]?.title == "Doc 1")
        #expect(assignments[2]?.title == "Docs")
        #expect(assignments[3] == nil, "an app the layout doesn't have stays put")
        #expect(assignments[4] == nil, "so does a window more than it saved")
    }

    @Test func framesAreKeptAsSharesOfTheDisplay() {
        let unit = WindowLayout.unit(rect(720, 75, 720, 800), in: Screens.landscape)
        #expect(unit == rect(0.5, 0, 0.5, 1))
        #expect(WindowLayout.frame(unit, in: Screens.portrait) == rect(1980, -500, 540, 1920))
        #expect(WindowLayout.frame(rect(0.25, 0.25, 0.5, 0.5), in: Screens.ultrawide) == rect(860, 350, 1720, 700))
        #expect(WindowLayout.unit(rect(0, 0, 10, 10), in: .zero) == .zero)
    }

    @Test func layoutsSurviveStorage() {
        #expect(WindowLayout.decode(WindowLayout.encode([layout])) == [layout])
        #expect(WindowLayout.decode(nil).isEmpty)
        #expect(WindowLayout.decode(Data("not json".utf8)).isEmpty)
    }
}
