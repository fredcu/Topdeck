// SPDX-License-Identifier: MIT
import CoreGraphics
import Testing

@testable import TopdeckFeatures

private func entry(
    _ id: Int, _ app: String, _ title: String, pid: pid_t = 1, minimized: Bool = false,
    bounds: CGRect? = nil
) -> SwitcherEntry {
    SwitcherEntry(id: id, pid: pid, appName: app, title: title, isMinimized: minimized, bounds: bounds)
}

struct SwitcherListTests {
    @Test func windowsOnScreenGoFrontToBackThenOpenThenMinimized() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let entries = [
            entry(0, "Zed", "z", minimized: true),
            entry(1, "Mail", "back", pid: 2, bounds: bounds),
            entry(2, "Notes", "other space"),
            entry(3, "Safari", "front", pid: 3, bounds: bounds.offsetBy(dx: 500, dy: 0)),
        ]
        let onScreen = [
            OnScreenWindow(windowID: 30, pid: 3, title: "front", bounds: bounds.offsetBy(dx: 500, dy: 0)),
            OnScreenWindow(windowID: 20, pid: 2, title: "back", bounds: bounds),
        ]
        let ids = SwitcherList.windowIDs(for: entries, onScreen: onScreen)
        #expect(ids == [1: 20, 3: 30])
        #expect(SwitcherList.ordered(entries, windowIDs: ids, onScreen: onScreen).map(\.id) == [3, 1, 2, 0])
    }

    @Test func twoWindowsOfOneAppAreToldApartByTitleAndNotMatchedTwice() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let entries = [entry(0, "A", "one", bounds: bounds), entry(1, "A", "two", bounds: bounds)]
        let onScreen = [
            OnScreenWindow(windowID: 8, pid: 1, title: "two", bounds: bounds),
            OnScreenWindow(windowID: 9, pid: 1, title: "one", bounds: bounds),
        ]
        #expect(SwitcherList.windowIDs(for: entries, onScreen: onScreen) == [0: 9, 1: 8])
    }

    @Test func filteringNeedsEveryWordInTheTitleOrAppIgnoringCaseAndAccents() {
        let entries = [entry(0, "Safari", "Café menu"), entry(1, "Mail", "Inbox"), entry(2, "Safari", "Docs")]
        #expect(SwitcherList.filter(entries, query: "  ").map(\.id) == [0, 1, 2])
        #expect(SwitcherList.filter(entries, query: "safari").map(\.id) == [0, 2])
        #expect(SwitcherList.filter(entries, query: "cafe SAF").map(\.id) == [0])
        #expect(SwitcherList.filter(entries, query: "zzz").isEmpty)
    }
}

struct SwitcherSelectionTests {
    @Test func startsOnTheSecondWindowOrTheLastGoingBackward() {
        #expect(SwitcherSelection.initial(count: 5, backward: false) == 1)
        #expect(SwitcherSelection.initial(count: 5, backward: true) == 4)
        #expect(SwitcherSelection.initial(count: 5, backward: false, frontIsHidden: true) == 0)
        #expect(SwitcherSelection.initial(count: 1, backward: false) == 0)
    }

    @Test func stepsWrapAtBothEnds() {
        #expect(SwitcherSelection.step(2, by: 1, count: 3) == 0)
        #expect(SwitcherSelection.step(0, by: -1, count: 3) == 2)
        #expect(SwitcherSelection.step(0, by: 1, count: 0) == 0)
    }

    @Test func rowsStayPutAtTheEdges() {
        #expect(SwitcherSelection.row(1, by: 1, columns: 3, count: 8) == 4)
        #expect(SwitcherSelection.row(4, by: -1, columns: 3, count: 8) == 1)
        #expect(SwitcherSelection.row(1, by: -1, columns: 3, count: 8) == 1)
        #expect(SwitcherSelection.row(6, by: 1, columns: 3, count: 8) == 6)
    }
}
