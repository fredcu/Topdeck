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
        NotchEvent.pointerEntered, .clicked, .selectSpace(.shelf), .showFeature(.notes), .activity(song), .dragEntered,
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
        let unpinned = after(.show, .clicked, .beginTextInput, .selectSpace(.shelf))
        #expect(unpinned.presentation == .focused(space: .shelf, pinned: false))
        let pinned = after(.show, .clicked, .togglePin, .beginTextInput, .selectSpace(.tools), .endTextInput)
        #expect(pinned.presentation == .pinned(space: .tools))
        let dragged = after(.show, .clicked, .beginTextInput, .dragEntered)
        #expect(dragged.presentation == .focused(space: .shelf, pinned: false))
        let shown = after(.show, .clicked, .beginTextInput, .showFeature(.usage))
        #expect(shown.presentation == .focused(space: .agents, pinned: false))
    }

    @Test func theClosedNotchAlwaysOpensOnNow() {
        #expect(
            after(.show, .clicked, .selectSpace(.tools), .dismiss, .clicked).presentation == .expanded(space: .now),
            "the space used last isn't where it opens next")
        var hovered = after(.show, .clicked, .selectSpace(.mac), .dismiss, .pointerEntered)
        _ = hovered.handle(.deadline(.hoverDwell))
        #expect(hovered.presentation == .expanded(space: .now))
        #expect(after(.show).lastSpace == .now, "Now is the default")
        let awake = Activity(
            feature: .timer, symbol: "cup.and.saucer.fill", title: "Awake", duration: .zero)
        var ongoing = after(.show, .setOngoing(awake), .pointerEntered)
        _ = ongoing.handle(.deadline(.hoverDwell))
        #expect(ongoing.presentation == .expanded(space: .now), "an ongoing activity doesn't pull it to its space")
        #expect(
            after(.show, .setSpaces(SpaceSet(hidden: [.now], enabled: [.capture])), .clicked).presentation
                == .expanded(space: .tools),
            "with Now hidden, the first space on show")
    }

    @Test func aDetailScreenSlidesOverMacAndGoesWhenTheSpaceOrTheNotchChanges() {
        var state = after(.show, .clicked, .selectSpace(.mac))
        #expect(state.detail == nil)
        _ = state.handle(.openDetail(.network))
        #expect(state.detail == .network && state.presentation == .expanded(space: .mac))
        _ = state.handle(.openDetail(.capture))
        #expect(state.detail == .network, "a feature that is not a Mac screen is ignored")
        _ = state.handle(.togglePin)
        #expect(state.detail == .network, "pinning keeps it")
        _ = state.handle(.selectSpace(.mac))
        #expect(state.detail == nil, "choosing the space again goes back to its page")
        _ = state.handle(.openDetail(.storage))
        _ = state.handle(.selectSpace(.agents))
        _ = state.handle(.selectSpace(.mac))
        #expect(state.detail == nil)
        _ = state.handle(.openDetail(.storage))
        _ = state.handle(.openDetail(nil))
        #expect(state.detail == nil)
        _ = state.handle(.openDetail(.storage))
        _ = state.handle(.dismiss)
        _ = state.handle(.clicked)
        #expect(state.presentation == .expanded(space: .now) && state.detail == nil, "a closed notch forgets it")
    }

    @Test func aDetailForAFeatureThatIsOffIsNotOpened() {
        var state = after(.show, .setSpaces(only(.performance, .sound)), .clicked, .selectSpace(.mac))
        _ = state.handle(.openDetail(.storage))
        #expect(state.detail == nil)
        _ = state.handle(.openDetail(.sound))
        #expect(state.detail == .sound)
        _ = state.handle(.setSpaces(only(.performance)))
        #expect(state.onScreen == [.performance], "its feature went off, so it no longer runs")
    }

    @Test func systemOpensWheneverPerformanceIsOnAndRunsOnlyWithSystemAdmin() {
        var state = after(.show, .setSpaces(only(.performance)), .clicked, .selectSpace(.mac))
        _ = state.handle(.openDetail(.admin))
        #expect(state.detail == .admin, "the process table is Performance's")
        #expect(state.onScreen == [.performance], "System Admin is off, so it does not run")
        _ = state.handle(.setSpaces(only(.performance, .admin)))
        #expect(state.onScreen == [.performance, .admin])
        _ = state.handle(.openDetail(nil))
        _ = state.handle(.setSpaces(only(.sound)))
        _ = state.handle(.openDetail(.admin))
        #expect(state.detail == nil, "with neither on there is no System")
    }

    @Test func showingAFeatureOpensItsSpaceOnItsDetailScreenIfItIsOne() {
        let clipboard = after(.show, .showFeature(.clipboard))
        #expect(clipboard.presentation == .expanded(space: .clipboard))
        let usage = after(.show, .showFeature(.usage))
        #expect(usage.presentation == .expanded(space: .agents) && usage.detail == nil)
        let storage = after(.show, .showFeature(.storage))
        #expect(storage.presentation == .expanded(space: .mac) && storage.detail == .storage)
        #expect(after(.show, .showFeature(.performance)).detail == nil)
        #expect(after(.show, .showFeature(.timer)).presentation == .expanded(space: .tools))
        #expect(after(.show, .clicked, .togglePin, .showFeature(.sound)).presentation == .pinned(space: .mac))
        let hidden = after(.show, .setSpaces(SpaceSet(hidden: [.tools], enabled: Set(FeatureID.allCases))))
        var found = hidden
        _ = found.handle(.showFeature(.timer))
        #expect(found.presentation == .expanded(space: .now), "a hidden home gives way to another space that shows it")
        var weather = hidden
        _ = weather.handle(.showFeature(.weather))
        #expect(weather.presentation == .expanded(space: .now), "weather lives on Now")
        var nowhere = after(
            .show, .setSpaces(SpaceSet(hidden: [.mac], enabled: Set(FeatureID.allCases))), .selectSpace(.shelf),
            .dismiss)
        _ = nowhere.handle(.showFeature(.network))
        #expect(nowhere.presentation == .expanded(space: .shelf), "no space on show holds it, so the last one opens")
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
        #expect(state.presentation == .expanded(space: .shelf))
        #expect(after(.show, .activity(drop), .clicked).presentation == .expanded(space: .shelf))
    }

    @Test func aSystemActivityShowsWhateverIsOnAndOpensTheLastSpace() {
        #expect(after(.show, .setSpaces(only(.notes)), .activity(volume)).presentation == .transient(volume))
        #expect(after(.show, .setSpaces(only()), .activity(volume)).presentation == .transient(volume))
        let retabbed = after(.show, .activity(volume), .setSpaces(only(.notes)))
        #expect(retabbed.presentation == .transient(volume), "it has no feature to lose")
        let opened = after(.show, .clicked, .selectSpace(.tools), .dismiss, .activity(volume), .clicked)
        #expect(opened.presentation == .expanded(space: .now), "a system activity opens Now")
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
        #expect(hovered.presentation == .expanded(space: .now))
        #expect(after(.show, .setOngoing(meeting), .clicked).presentation == .expanded(space: .now))
        let closed = after(.show, .setOngoing(meeting), .clicked, .dismiss)
        #expect(closed.restingActivity == meeting, "and it's back when the notch closes")
    }

    @Test func aRecordingIsHoveredForItsButtonsAndOnlyClickedOpen() {
        let recording = Activity(
            feature: .capture, symbol: "record.circle", title: "Recording", duration: .seconds(1),
            recording: .running(since: .now))
        var state = after(.show, .setOngoing(recording))
        #expect(state.handle(.pointerEntered).isEmpty, "no hover dwell: the deck would cover Pause and Stop")
        #expect(state.presentation == .compact && state.pointerInside && state.restingActivity == recording)
        _ = state.handle(.pointerExited)
        #expect(!state.pointerInside && state.presentation == .compact)
        #expect(after(.show, .setOngoing(recording), .clicked).presentation == .expanded(space: .now))
        #expect(
            after(.show, .setOngoing(recording), .pointerEntered, .clicked).presentation == .expanded(space: .now))
        // Anything else still opens on hover.
        #expect(after(.show, .setOngoing(meeting), .pointerEntered).presentation == .hoverArmed)
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
        #expect(state.presentation == .expanded(space: .shelf))
        #expect(state.handle(.dragExited) == [.schedule(.collapseGrace, after: NotchTiming.collapseGrace)])
        // Dragging back in cancels the collapse; dropping keeps the shelf open under the pointer.
        #expect(state.handle(.dragEntered) == [.cancel(.collapseGrace)])
        #expect(state.handle(.dropped) == [.cancel(.collapseGrace)])
        #expect(state.presentation == .expanded(space: .shelf))
        #expect(state.pointerInside)
    }

    @Test func draggingKeepsAPinAndIgnoresADisabledShelf() {
        #expect(after(.show, .clicked, .togglePin, .dragEntered).presentation == .pinned(space: .shelf))
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
        let hidden = SpaceSet(hidden: [.now, .shelf], enabled: Set(FeatureID.allCases))
        let pinned = after(.show, .clicked, .selectSpace(.shelf), .togglePin, .setSpaces(hidden))
        #expect(pinned.presentation == .pinned(space: .clipboard))
        #expect(pinned.lastSpace == .clipboard)
        let off = after(.show, .clicked, .selectSpace(.tools), .setSpaces(only(.media)))
        #expect(off.presentation == .expanded(space: .now), "tools has nothing on, so it left")
    }

    @Test func spacesAndFeaturesThatAreOffNeverOpenOrRaiseActivities() {
        #expect(after(.show, .setSpaces(only(.notes)), .selectSpace(.tools)).presentation == .expanded(space: .now))
        #expect(after(.show, .setSpaces(only(.notes)), .activity(song)).presentation == .compact)
        #expect(after(.show, .activity(song), .setSpaces(only(.notes))).presentation == .compact)
        #expect(after(.show, .setSpaces(only()), .clicked).presentation == .expanded(space: .now), "Now always opens")
    }

    @Test func whatIsOnScreenFollowsTheSpaceAndItsDetail() {
        func features(_ events: NotchEvent...) -> Set<FeatureID> { after(events).onScreen }
        #expect(features(.show).isEmpty)
        #expect(
            features(.show, .clicked) == [.media, .agents, .calendar, .notes, .weather, .timer], "everything Now shows")
        #expect(features(.show, .showFeature(.usage)) == [.agents, .usage], "one page")
        #expect(
            features(.show, .selectSpace(.mac)) == [.performance, .monitors], "Mac's page: performance and brightness")
        #expect(features(.show, .showFeature(.sound)) == [.performance, .monitors, .sound])
        #expect(features(.show, .showFeature(.clipboard)) == [.clipboard], "the one view")
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
        #expect(
            Set(now.filter { $0.value == .foreground }.keys) == [.media, .agents, .calendar, .notes, .weather, .timer])
        let clipboard = phases(after(.show, .showFeature(.clipboard)))
        #expect(Set(clipboard.filter { $0.value == .foreground }.keys) == [.clipboard])
        #expect(clipboard[.shelf] == .background && clipboard[.media] == .background)
        let usage = phases(after(.show, .showFeature(.usage)))
        #expect(Set(usage.filter { $0.value == .foreground }.keys) == [.agents, .usage], "both on one page")
        let storage = phases(after(.show, .showFeature(.storage)))
        #expect(Set(storage.filter { $0.value == .foreground }.keys) == [.performance, .monitors, .storage])
        #expect(storage[.network] == .background && storage[.admin] == .background)
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
                .setSpaces(only()), .setSpaces(SpaceSet(hidden: [.now, .shelf], enabled: Set(FeatureID.allCases))),
                .setOngoing(meeting), .setOngoing(nil),
            ] + FeatureID.allCases.map(NotchEvent.showFeature) + FeatureID.allCases.map { NotchEvent.openDetail($0) }
            + [.openDetail(nil)]
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
                if let detail = state.detail {
                    try #require(space.details.contains(detail), "\(event) showed \(detail) over \(space)")
                    try #require(
                        state.spaceSet.enabled.contains(detail), "\(event) showed the screen of an off feature")
                    try #require(state.onScreen.contains(detail))
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
