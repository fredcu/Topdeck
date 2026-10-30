// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import TopdeckCore

/// The deck with only these features on.
private func only(_ features: FeatureID...) -> SpaceSet { SpaceSet(enabled: Set(features)) }

private let song = Activity(feature: .media, symbol: "music.note", title: "Song", duration: .seconds(2))
private let drop = Activity(feature: .shelf, symbol: "tray.full", title: "2 files", duration: .seconds(1))
/// A system activity: it belongs to no feature.
private let volume = Activity(
    feature: nil, symbol: "speaker.wave.2.fill", title: "50%", level: 0.5, duration: .seconds(1))
/// An ongoing activity: it stays in the resting notch until its feature clears it.
private let meeting = Activity(
    feature: .calendar, symbol: "video.fill", title: "Standup", duration: .zero,
    countdown: Date(timeIntervalSince1970: 1_790_000_000))

/// The state a fresh reducer reaches after `events`.
private func after(_ events: NotchEvent...) -> NotchState { after(events) }

private func after(_ events: [NotchEvent]) -> NotchState {
    var state = NotchState()
    for event in events { _ = state.handle(event) }
    return state
}

struct NotchReducerTests {
    @Test func startsHiddenAndShowRevealsTheCompactNotch() {
        var state = NotchState()
        #expect(state.presentation == .hidden)
        #expect(state.handle(.show).isEmpty)
        #expect(state.presentation == .compact)
    }

    @Test(arguments: [
        NotchEvent.pointerEntered, .clicked, .selectSpace(.stash), .showFeature(.notes), .activity(song), .dragEntered,
    ])
    func hiddenIgnoresEverythingButShow(event: NotchEvent) {
        var state = NotchState()
        #expect(state.handle(event).isEmpty)
        #expect(state.presentation == .hidden)
    }

    @Test func hoverExpandsOnlyAfterTheDwell() {
        var state = after(.show)
        #expect(state.handle(.pointerEntered) == [.schedule(.hoverDwell, after: NotchTiming.hoverDwell)])
        #expect(state.presentation == .hoverArmed)
        #expect(state.handle(.deadline(.hoverDwell)).isEmpty)
        #expect(state.presentation == .expanded(space: .now))
    }

    @Test func aQuickPassDoesNotExpand() {
        var state = after(.show, .pointerEntered)
        #expect(state.handle(.pointerExited) == [.cancel(.hoverDwell)])
        #expect(state.presentation == .compact)
    }

    @Test func clickingExpandsWithoutWaiting() {
        #expect(after(.show, .clicked).presentation == .expanded(space: .now))
        var state = after(.show, .pointerEntered)
        #expect(state.handle(.clicked) == [.cancel(.hoverDwell)])
        #expect(state.presentation == .expanded(space: .now))
    }

    @Test func leavingStartsTheCollapseGraceAndReturningCancelsIt() {
        var state = after(.show, .clicked)
        #expect(state.handle(.pointerExited) == [.schedule(.collapseGrace, after: NotchTiming.collapseGrace)])
        #expect(state.handle(.pointerEntered) == [.cancel(.collapseGrace)])
        // A deadline that fires late, after the pointer came back, must not collapse the notch.
        #expect(state.handle(.deadline(.collapseGrace)).isEmpty)
        #expect(state.presentation == .expanded(space: .now))
    }

    @Test func theGraceRunningOutCollapses() {
        var state = after(.show, .clicked, .pointerExited)
        #expect(state.handle(.deadline(.collapseGrace)).isEmpty)
        #expect(state.presentation == .compact)
    }

    @Test(arguments: [NotchEvent.clickedOutside, .dismiss])
    func clickAwayAndEscapeCloseTheExpandedNotch(event: NotchEvent) {
        #expect(after(.show, .clicked, event).presentation == .compact)
    }

    @Test func pinnedStaysOpenUntilDismissed() {
        var state = after(.show, .clicked, .togglePin)
        #expect(state.presentation == .pinned(space: .now))
        #expect(state.presentation.isPinned)
        #expect(state.handle(.pointerExited).isEmpty)
        #expect(state.handle(.clickedOutside).isEmpty)
        #expect(state.presentation == .pinned(space: .now))
        #expect(state.handle(.dismiss).isEmpty)
        #expect(state.presentation == .compact)
    }

    @Test func pinningCancelsAPendingCollapse() {
        var state = after(.show, .clicked, .pointerExited)
        #expect(state.handle(.togglePin) == [.cancel(.collapseGrace)])
        #expect(state.presentation == .pinned(space: .now))
        #expect(state.handle(.togglePin).isEmpty)
        #expect(state.presentation == .expanded(space: .now))
    }

    @Test(arguments: [false, true])
    func textInputReturnsToWhereItStarted(pinned: Bool) {
        var state = after(pinned ? [.show, .clicked, .togglePin] : [.show, .clicked])
        _ = state.handle(.beginTextInput)
        #expect(state.presentation == .focused(space: .now, pinned: pinned))
        // Moving the pointer away mid-sentence must not close the notch.
        #expect(state.handle(.pointerExited).isEmpty)
        _ = state.handle(.endTextInput)
        #expect(state.presentation == (pinned ? .pinned(space: .now) : .expanded(space: .now)))
    }

    @Test func clickingAwayEndsTextInputButKeepsAPin() {
        #expect(after(.show, .clicked, .beginTextInput, .clickedOutside).presentation == .compact)
        let pinned = after(.show, .clicked, .togglePin, .beginTextInput, .clickedOutside)
        #expect(pinned.presentation == .pinned(space: .now))
    }

    @Test func switchingSpacesWhileTypingKeepsFocusAndThePin() {
        // The panel still has the keyboard, so leaving focus here would need a visible hand-back.
        let unpinned = after(.show, .clicked, .beginTextInput, .selectSpace(.stash))
        #expect(unpinned.presentation == .focused(space: .stash, pinned: false))
        let pinned = after(.show, .clicked, .togglePin, .beginTextInput, .selectSpace(.plan), .endTextInput)
        #expect(pinned.presentation == .pinned(space: .plan))
        let dragged = after(.show, .clicked, .beginTextInput, .dragEntered)
        #expect(dragged.presentation == .focused(space: .stash, pinned: false))
        #expect(dragged.subTab(in: .stash) == .shelf)
        let shown = after(.show, .clicked, .beginTextInput, .showFeature(.usage))
        #expect(shown.presentation == .focused(space: .agents, pinned: false))
    }

    @Test func theLastSpaceIsRemembered() {
        #expect(after(.show, .clicked, .selectSpace(.plan), .dismiss, .clicked).presentation == .expanded(space: .plan))
        #expect(after(.show).lastSpace == .now, "Now is the default")
    }

    @Test func eachSpaceRemembersItsLastSubTab() {
        var state = after(.show, .clicked, .selectSpace(.stash))
        #expect(state.subTab(in: .stash) == .shelf, "the first tab to begin with")
        _ = state.handle(.selectSubTab(.notes))
        _ = state.handle(.selectSpace(.mac))
        _ = state.handle(.selectSubTab(.network))
        _ = state.handle(.selectSpace(.stash))
        #expect(state.subTab(in: .stash) == .notes && state.subTab(in: .mac) == .network)
        _ = state.handle(.dismiss)
        _ = state.handle(.clicked)
        #expect(state.presentation == .expanded(space: .stash) && state.subTab(in: .stash) == .notes)
        #expect(state.subTab(in: .now) == nil && state.subTab(in: .plan) == nil, "no sub-tabs, nothing to remember")
    }

    @Test func aSubTabForAFeatureThatIsOffIsNotChosenOrKept() {
        var state = after(.show, .setSpaces(only(.shelf, .notes)), .clicked, .selectSpace(.stash))
        _ = state.handle(.selectSubTab(.clipboard))
        #expect(state.subTab(in: .stash) == .shelf, "clipboard is off")
        _ = state.handle(.selectSubTab(.notes))
        #expect(state.subTab(in: .stash) == .notes)
        _ = state.handle(.setSpaces(only(.shelf)))
        #expect(state.subTab(in: .stash) == .shelf, "notes went off, so the first tab left shows")
        _ = state.handle(.setSpaces(only(.shelf, .notes)))
        #expect(state.subTab(in: .stash) == .notes, "and it comes back when notes does")
    }

    @Test func showingAFeatureOpensItsSpaceOnItsSubTab() {
        let clipboard = after(.show, .showFeature(.clipboard))
        #expect(clipboard.presentation == .expanded(space: .stash) && clipboard.subTab(in: .stash) == .clipboard)
        #expect(after(.show, .showFeature(.timer)).presentation == .expanded(space: .tools))
        #expect(after(.show, .clicked, .togglePin, .showFeature(.sound)).presentation == .pinned(space: .mac))
        let hidden = after(.show, .setSpaces(SpaceSet(hidden: [.plan], enabled: Set(FeatureID.allCases))))
        var found = hidden
        _ = found.handle(.showFeature(.calendar))
        #expect(found.presentation == .expanded(space: .now), "a hidden home gives way to another space that shows it")
        var elsewhere = hidden
        _ = elsewhere.handle(.showFeature(.tasks))
        #expect(elsewhere.presentation == .expanded(space: .now), "tasks is on Now too")
        var nowhere = after(
            .show, .setSpaces(SpaceSet(hidden: [.mac], enabled: Set(FeatureID.allCases))), .selectSpace(.stash),
            .dismiss)
        _ = nowhere.handle(.showFeature(.network))
        #expect(nowhere.presentation == .expanded(space: .stash), "no space on show holds it, so the last one opens")
    }

    @Test func anActivityShowsUntilItsDeadline() {
        var state = after(.show)
        #expect(state.handle(.activity(song)) == [.schedule(.activityEnd, after: song.duration)])
        #expect(state.presentation == .transient(song))
        #expect(state.handle(.deadline(.activityEnd)).isEmpty)
        #expect(state.presentation == .compact)
    }

    @Test func aNewActivityReplacesTheCurrentOne() {
        var state = after(.show, .activity(song))
        #expect(state.handle(.activity(drop)) == [.schedule(.activityEnd, after: drop.duration)])
        #expect(state.presentation == .transient(drop))
    }

    @Test func hoveringAnActivityOpensItsFeature() {
        var state = after(.show, .activity(drop))
        let effects = state.handle(.pointerEntered)
        #expect(effects == [.cancel(.activityEnd), .schedule(.hoverDwell, after: NotchTiming.hoverDwell)])
        _ = state.handle(.deadline(.hoverDwell))
        #expect(state.presentation == .expanded(space: .stash))
        #expect(after(.show, .activity(drop), .clicked).presentation == .expanded(space: .stash))
    }

    @Test func aSystemActivityShowsWhateverIsOnAndOpensTheLastSpace() {
        #expect(after(.show, .setSpaces(only(.notes)), .activity(volume)).presentation == .transient(volume))
        #expect(after(.show, .setSpaces(only()), .activity(volume)).presentation == .transient(volume))
        let retabbed = after(.show, .activity(volume), .setSpaces(only(.notes)))
        #expect(retabbed.presentation == .transient(volume), "it has no feature to lose")
        let opened = after(.show, .clicked, .selectSpace(.plan), .dismiss, .activity(volume), .clicked)
        #expect(opened.presentation == .expanded(space: .plan), "a system activity opens the last space")
        var hovered = after(.show, .activity(volume))
        _ = hovered.handle(.pointerEntered)
        _ = hovered.handle(.deadline(.hoverDwell))
        #expect(hovered.presentation == .expanded(space: .now))
        #expect(after(.show, .setSpaces(only()), .activity(volume), .pointerEntered).presentation == .hoverArmed)
    }

    @Test func anOngoingActivityRestsInTheClosedNotchUntilItsFeatureClearsIt() {
        var state = after(.show)
        #expect(state.handle(.setOngoing(meeting)).isEmpty, "no deadline: it stays until it's cleared")
        #expect(state.presentation == .compact && state.restingActivity == meeting)
        _ = state.handle(.setOngoing(nil))
        #expect(state.restingActivity == nil)
        #expect(after(.setOngoing(meeting), .show).restingActivity == meeting, "it waits while the notch is hidden")
    }

    @Test func hoveringOrClickingAnOngoingActivityOpensItsFeature() {
        var hovered = after(.show, .setOngoing(meeting))
        _ = hovered.handle(.pointerEntered)
        #expect(hovered.restingActivity == meeting, "hovered, it stays in view, so the pointer stays on it")
        _ = hovered.handle(.deadline(.hoverDwell))
        #expect(hovered.presentation == .expanded(space: .plan))
        #expect(after(.show, .setOngoing(meeting), .clicked).presentation == .expanded(space: .plan))
        let closed = after(.show, .setOngoing(meeting), .clicked, .dismiss)
        #expect(closed.restingActivity == meeting, "and it's back when the notch closes")
    }

    @Test func oneShotActivitiesShowOverAnOngoingOne() {
        var state = after(.show, .setOngoing(meeting), .activity(song))
        #expect(state.presentation == .transient(song) && state.restingActivity == nil)
        _ = state.handle(.deadline(.activityEnd))
        #expect(state.restingActivity == meeting)
    }

    @Test func anOngoingActivityRestsOnlyWhileItsFeatureIsEnabled() {
        #expect(after(.show, .setOngoing(meeting), .setSpaces(only(.notes))).restingActivity == nil)
        let clicked = after(.show, .setSpaces(only(.notes)), .setOngoing(meeting), .clicked)
        #expect(clicked.presentation == .expanded(space: .now), "its feature is off, so it leads nowhere")
        let system = Activity(feature: nil, symbol: "bell.fill", title: "Hi", duration: .zero)
        #expect(
            after(.show, .setSpaces(only()), .setOngoing(system)).restingActivity == system, "a system one always rests"
        )
    }

    @Test func activitiesDoNotInterruptAnTopdeck() {
        var state = after(.show, .clicked)
        #expect(state.handle(.activity(song)).isEmpty)
        #expect(state.presentation == .expanded(space: .now))
    }

    @Test func draggingFilesNearTheClosedNotchMakesADropTarget() {
        var state = after(.show)
        #expect(state.handle(.dragEntered).isEmpty)
        #expect(state.presentation == .dropTarget && state.pointerInside)
        #expect(state.handle(.dragEntered).isEmpty, "entering again changes nothing")
        #expect(state.handle(.dragExited).isEmpty)
        #expect(state.presentation == .compact)
        _ = state.handle(.dragEntered)
        #expect(state.handle(.dropped).isEmpty)
        #expect(state.presentation == .compact, "the drop's own activity takes it from here")
        #expect(after(.show, .pointerEntered, .dragEntered).presentation == .dropTarget)
        #expect(after(.show, .activity(song), .dragEntered).presentation == .dropTarget)
        #expect(after(.show, .dragEntered, .dismiss).presentation == .compact)
    }

    @Test func draggingFilesOverAnOpenNotchShowsTheShelf() {
        var state = after(.show, .clicked)
        #expect(state.handle(.dragEntered) == [.cancel(.collapseGrace)])
        #expect(state.presentation == .expanded(space: .stash) && state.subTab(in: .stash) == .shelf)
        #expect(state.handle(.dragExited) == [.schedule(.collapseGrace, after: NotchTiming.collapseGrace)])
        // Dragging back in cancels the collapse; dropping keeps the shelf open under the pointer.
        #expect(state.handle(.dragEntered) == [.cancel(.collapseGrace)])
        #expect(state.handle(.dropped) == [.cancel(.collapseGrace)])
        #expect(state.presentation == .expanded(space: .stash))
        #expect(state.pointerInside)
    }

    @Test func draggingKeepsAPinAndIgnoresADisabledShelf() {
        #expect(after(.show, .clicked, .togglePin, .dragEntered).presentation == .pinned(space: .stash))
        #expect(after(.show, .setSpaces(only(.media, .notes)), .dragEntered).presentation == .compact)
        #expect(after(.show, .dragEntered, .setSpaces(only(.media))).presentation == .compact, "the shelf went off")
    }

    @Test func overlappingSuspensionsAllHaveToClear() {
        var state = after(.show, .clicked, .pointerExited)
        #expect(state.handle(.suspend(.screenLocked)) == [.cancel(.collapseGrace)])
        _ = state.handle(.suspend(.systemSleep))
        #expect(state.handle(.clicked).isEmpty)
        #expect(state.handle(.activity(song)).isEmpty)
        _ = state.handle(.resume(.systemSleep))
        #expect(state.presentation == .suspended, "still locked")
        _ = state.handle(.resume(.screenLocked))
        #expect(state.presentation == .compact)
    }

    @Test func aNotchShownWhileSuspendedStartsSuspended() {
        #expect(after(.suspend(.displaySleep), .show).presentation == .suspended)
        #expect(after(.suspend(.displaySleep), .show, .resume(.displaySleep)).presentation == .compact)
    }

    @Test func hidingTheOpenSpaceMovesToTheFirstOneOnShow() {
        let hidden = SpaceSet(hidden: [.now, .stash], enabled: Set(FeatureID.allCases))
        let pinned = after(.show, .clicked, .selectSpace(.stash), .togglePin, .setSpaces(hidden))
        #expect(pinned.presentation == .pinned(space: .plan))
        #expect(pinned.lastSpace == .plan)
        let off = after(.show, .clicked, .selectSpace(.plan), .setSpaces(only(.media)))
        #expect(off.presentation == .expanded(space: .now), "plan has nothing on, so it left")
    }

    @Test func spacesAndFeaturesThatAreOffNeverOpenOrRaiseActivities() {
        #expect(after(.show, .setSpaces(only(.notes)), .selectSpace(.plan)).presentation == .expanded(space: .now))
        #expect(after(.show, .setSpaces(only(.notes)), .activity(song)).presentation == .compact)
        #expect(after(.show, .activity(song), .setSpaces(only(.notes))).presentation == .compact)
        #expect(after(.show, .setSpaces(only()), .clicked).presentation == .expanded(space: .now), "Now always opens")
    }

    @Test func whatIsOnScreenFollowsTheSpaceAndItsSubTab() {
        func features(_ events: NotchEvent...) -> Set<FeatureID> { after(events).onScreen }
        #expect(features(.show).isEmpty)
        #expect(features(.show, .clicked) == [.media, .agents, .calendar, .tasks, .timer], "everything Now shows")
        #expect(features(.show, .selectSpace(.plan), .clicked) == [.calendar, .tasks])
        #expect(features(.show, .showFeature(.notes)) == [.notes], "one tab at a time")
        #expect(features(.show, .showFeature(.notes), .selectSubTab(.shelf)) == [.shelf])
        #expect(features(.show, .selectSpace(.tools)) == [.capture, .timer, .shortcuts])
        #expect(features(.show, .setSpaces(only(.media, .agents)), .selectSpace(.now)) == [.media, .agents])
    }

    @Test func eachFeatureRunsFullyOnlyWhileItsSpaceShowsIt() {
        let phases = { (state: NotchState) in
            Dictionary(uniqueKeysWithValues: FeatureID.allCases.map { ($0, state.phase(for: $0)) })
        }
        #expect(phases(after(.show)).values.allSatisfy { $0 == .background })
        #expect(phases(after()).values.allSatisfy { $0 == .stopped })
        let now = phases(after(.show, .clicked))
        #expect(Set(now.filter { $0.value == .foreground }.keys) == [.media, .agents, .calendar, .tasks, .timer])
        let clipboard = phases(after(.show, .showFeature(.clipboard)))
        #expect(Set(clipboard.filter { $0.value == .foreground }.keys) == [.clipboard])
        #expect(clipboard[.shelf] == .background && clipboard[.media] == .background)
        let usage = phases(after(.show, .showFeature(.usage), .selectSubTab(.agents)))
        #expect(Set(usage.filter { $0.value == .foreground }.keys) == [.agents], "the sessions tab, not usage")
        let suspended = phases(after(.show, .clicked, .suspend(.screenLocked)))
        #expect(suspended.values.allSatisfy { $0 == .stopped })
        let activity = phases(after(.show, .activity(drop)))
        #expect(activity[.shelf] == .foreground && activity[.notes] == .background)
    }

    @Test(arguments: [
        [NotchEvent.show], [.show, .pointerEntered], [.show, .clicked], [.show, .clicked, .togglePin],
        [.show, .clicked, .beginTextInput], [.show, .activity(song)], [.show, .suspend(.systemSleep)],
    ])
    func hideWorksFromEveryStateAndCancelsItsDeadline(path: [NotchEvent]) {
        var state = after(path)
        let owned = state.presentation.deadline
        #expect(state.handle(.hide) == (owned.map { [.cancel($0)] } ?? []))
        #expect(state.presentation == .hidden)
        #expect(!state.pointerInside)
    }

    /// Drives random events through the reducer while simulating a correct timer layer, checking
    /// after every step the invariants that the engine and the surface rely on.
    @Test func randomEventStreamsKeepTheInvariants() throws {
        var rng = SplitMix64(state: 0x0A11_CE5E_ED00_0001)
        let reasons: [SuspendReason] = [.systemSleep, .displaySleep, .screenLocked]
        let inputs: [NotchEvent] =
            [
                .show, .hide, .pointerEntered, .pointerExited, .clicked, .clickedOutside, .dismiss, .togglePin,
                .beginTextInput, .endTextInput, .dragEntered, .dragExited, .dropped, .activity(song),
                .activity(drop), .activity(volume), .setSpaces(.all), .setSpaces(only(.notes, .shelf)),
                .setSpaces(only()), .setSpaces(SpaceSet(hidden: [.now, .stash], enabled: Set(FeatureID.allCases))),
                .setOngoing(meeting), .setOngoing(nil),
            ] + FeatureID.allCases.map(NotchEvent.showFeature) + FeatureID.allCases.map(NotchEvent.selectSubTab)
            + SpaceID.allCases.map(NotchEvent.selectSpace) + reasons.map(NotchEvent.suspend)
            + reasons.map(NotchEvent.resume)
        var state = NotchState()
        var pending: Set<Deadline> = []
        var visited: Set<Substring> = []

        for _ in 0..<50_000 {
            let event: NotchEvent
            if let deadline = pending.first, Bool.random(using: &rng) {
                pending.remove(deadline)
                event = .deadline(deadline)
            } else {
                event = inputs.randomElement(using: &rng)!
            }
            for effect in state.handle(event) {
                switch effect {
                case .schedule(let deadline, _): pending.insert(deadline)
                case .cancel(let deadline): pending.remove(deadline)
                }
            }
            visited.insert(String(describing: state.presentation).prefix { $0 != "(" })

            let presentation = state.presentation
            let owned = Set([presentation.deadline].compactMap { $0 })
            try #require(pending.isSubset(of: owned), "\(event) left \(pending) pending in \(presentation)")
            if let space = presentation.openSpace {
                try #require(space == state.lastSpace)
                try #require(state.spaceSet.spaces.contains(space), "\(event) opened hidden \(space)")
                if let tab = state.subTab(in: space) {
                    try #require(state.spaceSet.enabled.contains(tab), "\(event) showed the sub-tab of an off feature")
                    try #require(state.onScreen == [tab])
                }
            }
            try #require(state.spaceSet.spaces.contains(state.lastSpace), "\(event) left a hidden space as the last")
            if case .transient(let activity) = presentation, let feature = activity.feature {
                try #require(state.spaceSet.enabled.contains(feature), "\(event) showed an off feature's activity")
            }
            if let resting = state.restingActivity {
                let closed = presentation == .compact || presentation == .hoverArmed
                try #require(closed, "\(event) showed an ongoing activity in \(presentation)")
                try #require(
                    resting.feature.map(state.spaceSet.enabled.contains) ?? true, "\(event) rested an off feature")
            }
            if presentation == .hoverArmed { try #require(state.pointerInside) }
            if presentation != .hidden {
                try #require((presentation == .suspended) == !state.suspensions.isEmpty, "\(event) → \(presentation)")
            }
        }
        #expect(visited.count == 9, "fuzzing only reached \(visited.sorted())")
    }
}

/// Small deterministic generator, so a fuzz failure replays exactly.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
