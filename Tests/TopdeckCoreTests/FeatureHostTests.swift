// SPDX-License-Identifier: MIT
import Testing

@testable import TopdeckCore

/// Records every phase the host moves it through.
@MainActor
private final class RecordingFeature: NotchFeature {
    let id: FeatureID
    private(set) var history: [FeaturePhase] = []
    var phase: FeaturePhase = .stopped { didSet { history.append(phase) } }

    init(_ id: FeatureID) { self.id = id }
}

/// The state a notch reaches after `events`.
private func notch(_ events: NotchEvent...) -> NotchState {
    var state = NotchState()
    for event in events { _ = state.handle(event) }
    return state
}

@MainActor
struct FeatureHostTests {
    private let all = Set(FeatureID.allCases)

    @Test func featuresFollowTheActivationPolicy() {
        let media = RecordingFeature(.media)
        let clipboard = RecordingFeature(.clipboard)
        let host = FeatureHost([media, clipboard])

        host.update(notches: [notch(.show)], enabled: all)
        #expect(media.phase == .background && clipboard.phase == .background)
        host.update(notches: [notch(.show, .clicked)], enabled: all)
        #expect(media.phase == .foreground && clipboard.phase == .background)
        host.update(notches: [notch(.show, .showFeature(.clipboard), .togglePin)], enabled: all)
        #expect(media.phase == .background && clipboard.phase == .foreground)
        host.update(notches: [notch(.show, .suspend(.screenLocked))], enabled: all)
        #expect(media.phase == .stopped && clipboard.phase == .stopped)
        #expect(media.history == [.background, .foreground, .background, .stopped])
    }

    @Test func aDetailScreenMovesTheForeground() {
        let performance = RecordingFeature(.performance)
        let storage = RecordingFeature(.storage)
        let host = FeatureHost([performance, storage])
        host.update(notches: [notch(.show, .showFeature(.performance))], enabled: all)
        #expect(performance.phase == .foreground && storage.phase == .background)
        host.update(notches: [notch(.show, .showFeature(.performance), .openDetail(.storage))], enabled: all)
        #expect(performance.phase == .foreground && storage.phase == .foreground)
        host.update(
            notches: [notch(.show, .showFeature(.performance), .openDetail(.storage), .openDetail(nil))], enabled: all)
        #expect(storage.phase == .background, "back to the page stops the screen's work")
    }

    @Test func aFeatureRunsAtTheHighestPhaseAnyDisplayAsks() {
        let media = RecordingFeature(.media)
        let host = FeatureHost([media])
        host.update(notches: [notch(.show), notch(.show, .clicked)], enabled: all)
        #expect(media.phase == .foreground)
        host.update(notches: [notch(.show, .suspend(.systemSleep)), notch(.show)], enabled: all)
        #expect(media.phase == .background)
        host.update(notches: [], enabled: all)
        #expect(media.phase == .stopped)
    }

    @Test func aLiveActivityBringsItsFeatureForward() {
        let shelf = RecordingFeature(.shelf)
        let host = FeatureHost([shelf])
        let activity = Activity(feature: .shelf, symbol: "tray.full", title: "1 file", duration: .seconds(1))
        host.update(notches: [notch(.show, .activity(activity))], enabled: all)
        #expect(shelf.phase == .foreground)
    }

    @Test func disabledFeaturesStayStopped() {
        let media = RecordingFeature(.media)
        let host = FeatureHost([media])
        host.update(notches: [notch(.show, .clicked)], enabled: [.notes])
        #expect(media.phase == .stopped)
        #expect(media.history.isEmpty, "a phase that doesn't change must not be reassigned")
    }
}
