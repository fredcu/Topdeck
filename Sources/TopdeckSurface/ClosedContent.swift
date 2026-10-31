// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import TopdeckCore

/// What the closed notch draws for a live activity, split the way the Closed board splits it: on the
/// left of the camera what it is, on the right its state. Derived from the activity alone, so
/// features keep raising the same `Activity` and the notch decides how it looks.
struct ClosedContent: Equatable {
    /// What it is, left of the camera.
    enum Leading: Equatable {
        case artwork(Data)
        case icon(DeckIcon)
        /// An SF Symbol the deck has no icon for.
        case symbol(String)
    }

    /// Its state, right of the camera.
    enum Trailing: Equatable {
        /// A level from 0 to 1: the volume, a battery's charge.
        case meter(Double)
        /// The time left until this moment.
        case countdown(Date)
        /// Four bars: moving while something plays, low and still while it's paused. The colour is the
        /// track's, nil for the Now accent.
        case equalizer(playing: Bool, accent: ActivityTint?)
        case icon(DeckIcon)
        case text(String)
        /// A count of what needs you.
        case badge(Int)
    }

    /// How the leading icon and label are colored.
    enum Tone: Equatable {
        case normal, signal, go
    }

    var leading: Leading
    /// Beside the leading icon: the name of what it is.
    var label: String?
    var tone: Tone = .normal
    var trailing: Trailing?
    /// The trailing text's tone: a meeting about to start is signal.
    var trailingTone: Tone = .normal
    /// The video call to join, beside the countdown of a meeting about to start.
    var join: URL?
    /// Read by VoiceOver in place of the pieces.
    var spoken: String

    // ponytail: derived from the feature and symbol the features already send; an explicit field on
    // `Activity` once more than these few need their own look.
    init(_ activity: Activity) {
        spoken = activity.title
        let symbol = activity.symbol
        let waiting = activity.feature == .agents && symbol == "hand.raised.fill"
        let finished = activity.feature == .agents && symbol == "checkmark.circle.fill"
        if let artwork = activity.artwork {
            leading = .artwork(artwork)
        } else if let icon = DeckIcon.matching(symbol: symbol) {
            leading = .icon(icon)
        } else {
            leading = .symbol(symbol)
        }

        if let level = activity.level {
            trailing = .meter(level)
        } else if let countdown = activity.countdown {
            trailing = .countdown(countdown)
            if activity.feature == .calendar {
                trailingTone = .signal
                join = activity.meetingLink
            }
        } else if activity.artwork != nil {
            trailing = .equalizer(playing: symbol != "pause.fill", accent: activity.accent)
        } else {
            label = activity.title
        }

        if waiting {
            tone = .signal
            // "3 waiting" names no project: say what it is, and count.
            if let count = Int(activity.title.split(separator: " ").first ?? ""), activity.title.hasSuffix("waiting") {
                label = "Agents"
                trailing = .badge(count)
            }
        } else if symbol == "checkmark.circle.fill" {
            tone = .go
            if finished { trailing = .text("Done") }
        }
    }

    /// Measured in the fonts the notch draws them in.
    private static var labelFont: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    private static var countdownFont: NSFont { .monospacedDigitSystemFont(ofSize: 13, weight: .semibold) }
    private static let iconSide: CGFloat = 16
    static let artworkSide: CGFloat = 24
    static let meterWidth: CGFloat = 92
    /// The Join button's label, and the gap between it and the minutes.
    private static var joinFont: NSFont { .systemFont(ofSize: 12, weight: .semibold) }
    static let joinPadding: CGFloat = 9
    static let joinSpacing: CGFloat = 8

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    /// The leading icon and its label.
    var leadingWidth: CGFloat {
        let icon: CGFloat
        if case .artwork = leading { icon = Self.artworkSide } else { icon = Self.iconSide }
        guard let label else { return icon }
        return icon + NotchMetrics.closedSpacing + Self.width(label, Self.labelFont)
    }

    /// The trailing state, or nothing.
    var trailingWidth: CGFloat {
        switch trailing {
        case nil: 0
        case .meter: Self.meterWidth
        case .countdown(let end):
            // A meeting's minutes, with its Join button.
            if join != nil {
                Self.width("5 min", Self.countdownFont) + Self.joinSpacing + Self.width("Join", Self.joinFont)
                    + Self.joinPadding * 2
            } else {
                // Room for its longest reading, so the notch doesn't breathe as digits change.
                Self.width(end.timeIntervalSinceNow >= 3600 ? "0:00:00" : "00:00", Self.countdownFont)
            }
        case .equalizer: CGFloat(MusicBars.width)
        case .icon: Self.iconSide
        case .text(let text): Self.width(text, Self.labelFont)
        case .badge(let count): count > 9 ? 22 : 16
        }
    }
}
