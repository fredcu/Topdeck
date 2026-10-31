// SPDX-License-Identifier: MIT
import Foundation

/// A feature that can own the expanded notch.
public enum FeatureID: String, CaseIterable, Hashable, Sendable {
    case media, sound, shelf, clipboard, capture, calendar, tasks, notes, shortcuts, timer, storage, network
    case usage, agents, monitors, admin, performance

    /// SF Symbol for the feature's page in Settings, beside System Settings' own symbols. The deck
    /// itself shows text labels and its own icons. Every name here exists on macOS 14.6, the oldest
    /// supported.
    public var symbol: String {
        switch self {
        case .media: "play.circle"
        case .sound: "speaker.wave.2"
        case .shelf: "tray.full"
        case .clipboard: "list.clipboard"
        case .capture: "camera.viewfinder"
        case .calendar: Self.today
        case .tasks: "checklist"
        case .notes: "note.text"
        case .shortcuts: "square.2.layers.3d"
        case .timer: "timer"
        case .storage: "internaldrive"
        case .network: "arrow.up.arrow.down.circle"
        case .usage: "gauge.with.needle"
        case .agents: "apple.terminal"
        case .admin: "gearshape.2"
        case .monitors: "display.2"
        case .performance: "cpu"
        }
    }

    /// Today's date on a calendar page, like the Calendar app's icon, where macOS has those symbols.
    private static var today: String {
        guard #available(macOS 26, *) else { return "calendar" }
        return "\(Calendar.current.component(.day, from: .now)).calendar"
    }

    public var title: String {
        switch self {
        case .media: "Media"
        case .sound: "Sound"
        case .shelf: "Shelf"
        case .clipboard: "Clipboard"
        case .capture: "Capture"
        case .calendar: "Calendar"
        case .tasks: "Tasks"
        case .notes: "Notes"
        case .shortcuts: "Shortcuts"
        case .timer: "Timer"
        case .storage: "Storage"
        case .network: "Network"
        case .usage: "AI Usage"
        case .agents: "Agents"
        case .admin: "System Admin"
        case .monitors: "Monitors"
        case .performance: "Performance"
        }
    }
}

/// A live activity shown on the compact notch: one-shot, such as a track change, a file drop, or
/// the volume changing, or ongoing, such as a meeting about to start, until its feature clears it.
public struct Activity: Hashable, Sendable {
    /// The feature that raised it, whose space opens when it's hovered or clicked. Nil for a system
    /// activity, such as volume or battery, that belongs to no feature and always shows.
    public var feature: FeatureID?
    /// SF Symbol shown just before the title.
    public var symbol: String
    /// Short text: under the camera for a one-shot activity, beside it for an ongoing one.
    public var title: String
    /// 0...1 for a meter beside the title, such as the volume or the battery's charge.
    public var level: Double?
    /// How long a one-shot activity shows. Ongoing activities ignore it.
    public var duration: Duration
    /// Shown instead of the title: the time left until this moment, ticking down to 0:00.
    public var countdown: Date?
    /// A small encoded image shown in place of the symbol, such as the cover of what's playing.
    public var artwork: Data?
    /// The video call of a meeting about to start, which the closed notch offers as a Join button.
    public var meetingLink: URL?

    public init(
        feature: FeatureID?, symbol: String, title: String, level: Double? = nil, duration: Duration,
        countdown: Date? = nil, artwork: Data? = nil, meetingLink: URL? = nil
    ) {
        self.feature = feature
        self.symbol = symbol
        self.title = title
        self.level = level
        self.duration = duration
        self.countdown = countdown
        self.artwork = artwork
        self.meetingLink = meetingLink
    }
}

/// Why the notch is out of the way. Reasons overlap (a Mac can sleep while locked), so the
/// notch comes back only once every reason has cleared.
public enum SuspendReason: Hashable, Sendable {
    case systemSleep
    case displaySleep
    case screenLocked
    /// A full-screen app fills the display, as it does on one without a notch.
    case fullScreen
}

/// Everything the notch can be doing. One value replaces the prototype's `isOpen` flag,
/// so contradictory combinations (pinned but closed, focused while hidden) can't exist.
public enum NotchPresentationState: Hashable, Sendable {
    /// Not attached to a display.
    case hidden
    /// Resting: a black lip around the physical notch.
    case compact
    /// The pointer is on the notch; it expands once `NotchTiming.hoverDwell` passes.
    case hoverArmed
    /// Open while in use; collapses `NotchTiming.collapseGrace` after the pointer leaves.
    case expanded(space: SpaceID)
    /// Open until dismissed; ignores the pointer leaving and click-away.
    case pinned(space: SpaceID)
    /// Taking text input. Stays open and remembers whether it was pinned.
    case focused(space: SpaceID, pinned: Bool)
    /// Showing a live activity on the compact notch.
    case transient(Activity)
    /// Files are being dragged near the closed notch: it grows into a drop target for the shelf.
    case dropTarget
    /// Out of the way: sleep, display sleep, screen lock, or a full-screen app.
    case suspended

    /// The space on screen when the notch is open.
    public var openSpace: SpaceID? {
        switch self {
        case .expanded(let space), .pinned(let space), .focused(let space, _): space
        default: nil
        }
    }

    /// Whether the notch stays open when the pointer leaves or the user clicks elsewhere.
    public var isPinned: Bool {
        switch self {
        case .pinned, .focused(_, true): true
        default: false
        }
    }

    /// The one deadline this state may have pending.
    var deadline: Deadline? {
        switch self {
        case .hoverArmed: .hoverDwell
        case .expanded: .collapseGrace
        case .transient: .activityEnd
        default: nil
        }
    }
}

/// Inputs to the reducer. Pointer, keyboard, feature, and system callbacks all become one of these.
public enum NotchEvent: Hashable, Sendable {
    case show
    case hide
    case pointerEntered
    case pointerExited
    /// Primary click (or a pull-down scroll) on the notch itself.
    case clicked
    /// Click anywhere outside the notch.
    case clickedOutside
    /// Escape or a close control.
    case dismiss
    case selectSpace(SpaceID)
    /// Chooses a sub-tab of the open space (and remembers it for next time). Only a feature that is
    /// on, and a tab of some space, counts.
    case selectSubTab(FeatureID)
    /// Opens the space that shows `feature`, on its sub-tab if it is one: a shortcut, a command.
    case showFeature(FeatureID)
    case togglePin
    case beginTextInput
    case endTextInput
    /// Files are being dragged over the notch.
    case dragEntered
    case dragExited
    /// Files were dropped on the notch.
    case dropped
    case activity(Activity)
    /// The activity the resting notch shows until it's replaced or cleared (nil).
    case setOngoing(Activity?)
    /// The spaces on show, or the features that are on, changed.
    case setSpaces(SpaceSet)
    case suspend(SuspendReason)
    case resume(SuspendReason)
    /// A deadline requested by an earlier `NotchEffect.schedule` fired.
    case deadline(Deadline)
}

/// Timers the reducer can ask for. Each belongs to exactly one presentation state.
public enum Deadline: Hashable, Sendable {
    case hoverDwell
    case collapseGrace
    case activityEnd
}

/// Work the reducer asks its runner to do. Scheduling a pending deadline replaces it.
public enum NotchEffect: Hashable, Sendable {
    case schedule(Deadline, after: Duration)
    case cancel(Deadline)
}

/// Pointer hysteresis timings.
public enum NotchTiming {
    // ponytail: hand-picked defaults; calibrate on hardware with the Phase 2 surface.
    /// How long the pointer rests on the notch before it expands.
    public static let hoverDwell: Duration = .milliseconds(100)
    /// How long the pointer may stray from the expanded notch before it collapses.
    public static let collapseGrace: Duration = .milliseconds(250)
}

/// The reducer's whole world: the presentation plus the facts it must carry across states.
public struct NotchState: Hashable, Sendable {
    public private(set) var presentation: NotchPresentationState = .hidden
    /// The space to show the next time the notch expands. Always one on show. Now to begin with.
    public private(set) var lastSpace: SpaceID = .now
    /// What the deck offers: the spaces on show, in order, and the features that are on. The notch
    /// never opens a space missing from it.
    public private(set) var spaceSet = SpaceSet.all
    /// Each space's last sub-tab.
    public private(set) var subTabs: [SpaceID: FeatureID] = [:]
    /// Every reason the notch is currently suspended.
    public private(set) var suspensions: Set<SuspendReason> = []
    /// Kept in every state so a late collapse deadline can't close a notch the pointer is on.
    public private(set) var pointerInside = false
    /// Shown by the resting notch instead of hiding behind the camera housing, while its feature
    /// is enabled. One-shot activities show over it.
    public private(set) var ongoing: Activity?

    public init() {}

    /// The ongoing activity the notch shows right now: while it rests, and while the pointer is on it
    /// on the way to opening (so the notch doesn't shrink out from under the pointer), and only for
    /// an enabled feature.
    public var restingActivity: Activity? {
        guard presentation == .compact || presentation == .hoverArmed, let ongoing, shows(ongoing) else { return nil }
        return ongoing
    }

    /// The sub-tab on screen in `space`: the remembered one while its feature is on, else the first
    /// that is. Nil for a space without sub-tabs, or with none of them on.
    public func subTab(in space: SpaceID) -> FeatureID? {
        let offered = spaceSet.subTabs(of: space)
        if let remembered = subTabs[space], offered.contains(remembered) { return remembered }
        return offered.first
    }

    /// The features the open space is showing right now.
    public var onScreen: Set<FeatureID> {
        guard let space = presentation.openSpace else { return [] }
        return spaceSet.visibleFeatures(in: space, subTab: subTab(in: space))
    }

    /// Activation policy: what is on screen runs fully, the others keep only cheap observers, and
    /// nothing runs while the notch is hidden or suspended. A live activity's feature runs fully too.
    public func phase(for feature: FeatureID) -> FeaturePhase {
        switch presentation {
        case .hidden, .suspended: .stopped
        case .transient(let activity): activity.feature == feature ? .foreground : .background
        default: onScreen.contains(feature) ? .foreground : .background
        }
    }

    /// Applies one event and returns the effects to run. Pure: no clocks, no I/O.
    public mutating func handle(_ event: NotchEvent) -> [NotchEffect] {
        switch event {
        case .pointerEntered, .dragEntered, .dropped: pointerInside = true
        case .pointerExited, .dragExited: pointerInside = false
        default: break
        }
        let before = presentation
        var effects = transition(on: event)
        // Leaving a state cancels the deadline it owned, so at most one deadline is ever pending.
        if let owned = before.deadline, owned != presentation.deadline, event != .deadline(owned) {
            effects.insert(.cancel(owned), at: 0)
        }
        return effects
    }

    /// Every (state, event) pair not listed here is deliberately a no-op, including late deadlines.
    private mutating func transition(on event: NotchEvent) -> [NotchEffect] {
        switch (presentation, event) {
        // Settings apply in every state.
        case (_, .setSpaces(let set)):
            spaceSet = set
            if !set.spaces.contains(lastSpace), let first = set.spaces.first { lastSpace = first }
            switch presentation {
            case .expanded(let space), .pinned(let space), .focused(let space, _):
                guard !set.spaces.contains(space) else { break }
                if let first = set.spaces.first {
                    open(first, pinned: presentation.isPinned)
                } else {
                    presentation = .compact
                }
            case .transient(let activity) where !shows(activity):
                presentation = .compact
            case .hoverArmed where set.spaces.isEmpty:
                presentation = .compact
            case .dropTarget where !set.enabled.contains(.shelf):
                presentation = .compact
            default:
                break
            }
        case (_, .setOngoing(let activity)):
            ongoing = activity

        // Suspending, attaching, and detaching win over everything else.
        case (_, .suspend(let reason)):
            suspensions.insert(reason)
            if presentation != .hidden {
                presentation = .suspended
                pointerInside = false
            }
        case (_, .resume(let reason)):
            suspensions.remove(reason)
            if presentation == .suspended, suspensions.isEmpty { presentation = .compact }
        case (.hidden, .show):
            presentation = suspensions.isEmpty ? .compact : .suspended
        case (.hidden, _):
            break
        case (_, .hide):
            presentation = .hidden
            pointerInside = false
        case (.suspended, _):
            break

        // Opening. Like a live activity, an ongoing one opens the space that shows its feature.
        case (.compact, .pointerEntered):
            aim(at: restingActivity?.feature)
            presentation = .hoverArmed
            return [.schedule(.hoverDwell, after: NotchTiming.hoverDwell)]
        case (.compact, .clicked):
            aim(at: restingActivity?.feature)
            open(lastSpace)
        case (.transient(let activity), .pointerEntered):
            // Hovering a live activity opens the space of the feature that raised it, or the last
            // space for a system activity.
            aim(at: activity.feature)
            presentation = .hoverArmed
            return [.schedule(.hoverDwell, after: NotchTiming.hoverDwell)]
        case (.hoverArmed, .clicked), (.hoverArmed, .deadline(.hoverDwell)):
            open(lastSpace)
        case (.transient(let activity), .clicked):
            aim(at: activity.feature)
            open(lastSpace)
        case (.hoverArmed, .pointerExited), (.hoverArmed, .dragExited), (.hoverArmed, .dismiss):
            presentation = .compact

        // Dragging files near the closed notch makes it a drop target; over an open one it shows the shelf.
        case (.dropTarget, .dragEntered):
            break
        case (.compact, .dragEntered), (.hoverArmed, .dragEntered), (.transient, .dragEntered):
            guard spaceSet.enabled.contains(.shelf) else { break }
            presentation = .dropTarget
        case (.dropTarget, .dragExited), (.dropTarget, .dropped), (.dropTarget, .dismiss):
            presentation = .compact
        case (.focused(_, let pinned), .dragEntered) where spaceSet.enabled.contains(.shelf):
            aim(at: .shelf)
            presentation = .focused(space: lastSpace, pinned: pinned)
        case (_, .dragEntered) where spaceSet.enabled.contains(.shelf):
            let hadGrace = presentation.deadline == .collapseGrace
            aim(at: .shelf)
            open(lastSpace, pinned: presentation.isPinned)
            return hadGrace ? [.cancel(.collapseGrace)] : []
        case (.expanded, .dragExited):
            return [.schedule(.collapseGrace, after: NotchTiming.collapseGrace)]
        case (.expanded, .dropped):
            return [.cancel(.collapseGrace)]

        // Live activities show only while the notch is closed, and only for enabled features.
        case (.compact, .activity(let activity)) where shows(activity),
            (.transient, .activity(let activity)) where shows(activity):
            presentation = .transient(activity)
            return [.schedule(.activityEnd, after: activity.duration)]
        case (.transient, .deadline(.activityEnd)), (.transient, .dismiss):
            presentation = .compact

        // Expanded
        case (.expanded, .pointerEntered):
            return [.cancel(.collapseGrace)]
        case (.expanded, .pointerExited):
            return [.schedule(.collapseGrace, after: NotchTiming.collapseGrace)]
        case (.expanded, .deadline(.collapseGrace)) where !pointerInside:
            presentation = .compact
        case (.expanded, .clickedOutside), (.expanded, .dismiss):
            presentation = .compact
        case (.expanded(let space), .togglePin):
            open(space, pinned: true)
        case (.expanded(let space), .beginTextInput):
            presentation = .focused(space: space, pinned: false)

        // Pinned
        case (.pinned(let space), .togglePin):
            open(space)
        case (.pinned(let space), .beginTextInput):
            presentation = .focused(space: space, pinned: true)
        case (.pinned, .dismiss):
            presentation = .compact

        // Focused
        case (.focused(let space, let pinned), .endTextInput):
            open(space, pinned: pinned)
        case (.focused(let space, let pinned), .togglePin):
            presentation = .focused(space: space, pinned: !pinned)
        case (.focused(let space, true), .clickedOutside):
            open(space, pinned: true)
        case (.focused, .clickedOutside), (.focused, .dismiss):
            presentation = .compact

        // Choosing a space or a feature opens it and keeps a pin. While the notch has the keyboard,
        // switching keeps focus too: text entry ends only when the panel loses the keyboard or is dismissed.
        case (.focused(_, let pinned), .selectSpace(let space)) where spaceSet.spaces.contains(space):
            lastSpace = space
            presentation = .focused(space: space, pinned: pinned)
        case (.focused(_, let pinned), .showFeature(let feature)) where spaceSet.target(for: feature) != nil:
            aim(at: feature)
            presentation = .focused(space: lastSpace, pinned: pinned)
        case (_, .selectSpace(let space)):
            open(space, pinned: presentation.isPinned)
        case (_, .showFeature(let feature)):
            aim(at: feature)
            open(lastSpace, pinned: presentation.isPinned)
        case (_, .selectSubTab(let feature)):
            if let space = feature.subTabSpace, spaceSet.subTabs(of: space).contains(feature) {
                subTabs[space] = feature
            }

        default:
            break
        }
        return []
    }

    /// A feature's activity shows while the feature is on; a system activity always does.
    private func shows(_ activity: Activity) -> Bool {
        activity.feature.map(spaceSet.enabled.contains) ?? true
    }

    /// Makes `feature`'s space the one to open next, and its sub-tab the one that space shows. A
    /// feature on no space on show, or none, leaves the last space as it was.
    private mutating func aim(at feature: FeatureID?) {
        guard let feature, spaceSet.enabled.contains(feature), let space = spaceSet.target(for: feature) else { return }
        lastSpace = space
        if space.hasSubTabs, spaceSet.subTabs(of: space).contains(feature) { subTabs[space] = feature }
    }

    /// Opens `space`, or the first space on show if it isn't one.
    private mutating func open(_ space: SpaceID, pinned: Bool = false) {
        guard let space = spaceSet.spaces.contains(space) ? space : spaceSet.spaces.first else { return }
        lastSpace = space
        presentation = pinned ? .pinned(space: space) : .expanded(space: space)
    }
}
