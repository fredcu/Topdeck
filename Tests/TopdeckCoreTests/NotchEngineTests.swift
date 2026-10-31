// SPDX-License-Identifier: MIT
import Testing

@testable import TopdeckCore

@MainActor
struct NotchEngineTests {
    @Test func presentationChangesAreReportedOnce() {
        let engine = NotchEngine()
        var changes: [NotchPresentationState] = []
        engine.onPresentationChange = { _, new in changes.append(new) }
        engine.send(.show)
        engine.send(.pointerExited)  // pointer bookkeeping only
        engine.send(.clicked)
        engine.send(.clicked)  // already open
        #expect(changes == [.compact, .expanded(space: .now)])
    }

    @Test func aDetailScreenIsReportedSoFeaturesCanFollowIt() {
        let engine = NotchEngine()
        var reports = 0
        engine.send(.show)
        engine.send(.showFeature(.performance))
        engine.onPresentationChange = { _, _ in reports += 1 }
        engine.send(.openDetail(.storage))
        engine.send(.openDetail(.storage))  // already there
        #expect(reports == 1 && engine.state.onScreen == [.performance, .storage])
    }

    @Test func timersFireThroughTheReducer() async throws {
        let engine = NotchEngine()
        engine.send(.show)
        engine.send(.pointerEntered)
        #expect(engine.pendingDeadlines == [.hoverDwell])
        #expect(await eventually { engine.state.presentation == .expanded(space: .now) })
        #expect(engine.pendingDeadlines.isEmpty)
    }

    @Test func leavingAStateCancelsItsTimer() {
        let engine = NotchEngine()
        engine.send(.show)
        engine.send(.pointerEntered)
        engine.send(.pointerExited)
        #expect(engine.pendingDeadlines.isEmpty)
    }

    @Test func aMissedEnterCannotCollapseANotchThePointerIsOn() {
        let engine = NotchEngine()
        engine.pointerCheck = { PointerCheck(isInside: true, isButtonDown: false) }
        engine.send(.show)
        engine.send(.clicked)
        engine.send(.pointerExited)  // spurious: the pointer never left
        engine.fire(.collapseGrace)
        #expect(engine.state.presentation == .expanded(space: .now))
        #expect(engine.state.pointerInside && engine.pendingDeadlines.isEmpty)
    }

    @Test func nothingCollapsesWhileAMouseButtonIsHeld() {
        let engine = NotchEngine()
        engine.pointerCheck = { PointerCheck(isInside: false, isButtonDown: true) }
        engine.send(.show)
        engine.send(.clicked)
        engine.send(.pointerExited)
        engine.fire(.collapseGrace)
        #expect(engine.state.presentation == .expanded(space: .now))
        #expect(engine.pendingDeadlines == [.collapseGrace], "it looks again after another grace period")
        engine.pointerCheck = { PointerCheck(isInside: false, isButtonDown: false) }
        engine.fire(.collapseGrace)
        #expect(engine.state.presentation == .compact)
    }

    @Test func aStrayEnterCannotOpenTheNotch() {
        let engine = NotchEngine()
        engine.pointerCheck = { PointerCheck(isInside: false, isButtonDown: false) }
        engine.send(.show)
        engine.send(.pointerEntered)
        engine.fire(.hoverDwell)
        #expect(engine.state.presentation == .compact)
        #expect(engine.pendingDeadlines.isEmpty)
    }

    @Test func anInjectedDeadlineConsumesItsTimer() {
        let engine = NotchEngine()
        engine.send(.show)
        engine.send(.pointerEntered)
        engine.send(.deadline(.hoverDwell))
        #expect(engine.state.presentation == .expanded(space: .now))
        #expect(engine.pendingDeadlines.isEmpty)
    }
}
