// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckCore

/// A live activity in the closed notch, as the Closed board draws it: what it is to the left of the
/// camera, its state to the right, both at the camera's height. Nothing is drawn over the camera.
struct ClosedNotchView: View {
    let content: ClosedContent
    let metrics: NotchMetrics
    /// Opens a meeting's link, from the Join button.
    var join: (URL) -> Void = { _ in }

    var body: some View {
        Group {
            if metrics.notch != nil {
                let wings = metrics.closedWings(for: content)
                HStack(spacing: 0) {
                    leading
                        .padding(.leading, NotchMetrics.flare + NotchMetrics.closedPadding)
                        .frame(width: wings.leading, alignment: .leading)
                    // Nothing under the camera housing, where it couldn't be seen.
                    Color.clear.frame(width: metrics.housing.width)
                    trailing
                        .padding(.trailing, NotchMetrics.flare + NotchMetrics.closedPadding)
                        .frame(width: wings.trailing, alignment: .trailing)
                }
            } else {
                // Inside the pill, both ends of one row.
                HStack(spacing: NotchMetrics.closedPadding) {
                    leading
                    Spacer(minLength: 0)
                    trailing
                }
                .padding(.horizontal, NotchMetrics.closedPadding)
            }
        }
        .frame(height: metrics.housing.height)
        .foregroundStyle(Deck.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.spoken)
        .accessibilityActions {
            if let link = content.join { Button("Join meeting") { join(link) } }
        }
    }

    private func color(_ tone: ClosedContent.Tone) -> Color {
        switch tone {
        case .normal: Deck.text
        case .signal: Deck.signal
        case .go: Deck.go
        }
    }

    private var leading: some View {
        HStack(spacing: NotchMetrics.closedSpacing) {
            switch content.leading {
            case .artwork(let data):
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: ClosedContent.artworkSide, height: ClosedContent.artworkSide)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            case .icon(let icon):
                DeckIconView(icon).foregroundStyle(color(content.tone))
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(color(content.tone))
            }
            if let label = content.label {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color(content.tone))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        switch content.trailing {
        case nil:
            EmptyView()
        case .meter(let level):
            Capsule()
                .fill(Deck.control)
                .frame(width: ClosedContent.meterWidth, height: 5)
                .overlay(alignment: .leading) {
                    Capsule().fill(Deck.text).frame(width: ClosedContent.meterWidth * min(max(level, 0), 1))
                }
        case .countdown(let end):
            if let link = content.join {
                meetingCountdown(end, link: link)
            } else {
                countdown(end)
            }
        case .equalizer(let playing, let accent):
            MusicBarsView(playing: playing, tint: accent.map { Color(red: $0.red, green: $0.green, blue: $0.blue) })
        case .icon(let icon):
            DeckIconView(icon).foregroundStyle(Deck.secondary)
        case .text(let text):
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Deck.secondary).lineLimit(1)
        case .badge(let count):
            DeckBadge(count)
        }
    }

    /// "4 min" in signal, and the Join button that opens the call.
    private func meetingCountdown(_ end: Date, link: URL) -> some View {
        HStack(spacing: ClosedContent.joinSpacing) {
            // ponytail: redraws once a second while a meeting countdown shows, like the timer's.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let minutes = max(1, Int((end.timeIntervalSince(context.date) / 60).rounded(.up)))
                Text("\(minutes) min")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(color(content.trailingTone))
                    .lineLimit(1)
            }
            Button("Join") { join(link) }
                .buttonStyle(.deck(.accent, compact: true))
                .accessibilityLabel("Join meeting")
        }
    }

    private func countdown(_ end: Date) -> some View {
        // ponytail: redraws once a second while a countdown shows; a per-minute timeline if a
        // soak ever notices.
        let now = Date.now
        return Text(timerInterval: now...max(end, now), countsDown: true)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color(content.trailingTone))
            .lineLimit(1)
    }
}

/// Four thin bars in the track's colour, as the Closed board draws what's playing: they move to a made-up
/// pattern (`MusicBars`) at about 20 frames a second while the music plays and the notch is on screen, and
/// stand still, low, when it's paused. With Reduce Motion on they stand still in the middle of the range.
/// Only the moving case has a timeline: a still one has nothing that wakes up.
struct MusicBarsView: View {
    let playing: Bool
    /// The track's colour; the Now accent when it has none.
    let tint: Color?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if MusicBars.animates(playing: playing, reduceMotion: reduceMotion) {
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                    bars(MusicBars.heights(at: context.date.timeIntervalSinceReferenceDate))
                }
            } else {
                bars(playing ? MusicBars.still : MusicBars.resting)
            }
        }
        .frame(height: CGFloat(MusicBars.maxHeight))
        .accessibilityHidden(true)
    }

    private func bars(_ heights: [Double]) -> some View {
        HStack(alignment: .bottom, spacing: CGFloat(MusicBars.gap)) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(tint ?? Deck.Accent.now)
                    .frame(width: CGFloat(MusicBars.barWidth), height: CGFloat(heights[index]))
            }
        }
    }
}

/// The closed notch with a file dragged near: a drop target for the shelf, under the camera.
struct DropTargetView: View {
    var body: some View {
        HStack(spacing: 8) {
            DeckIconView(.share)
            Text("Drop on Shelf").font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(Deck.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }
}
