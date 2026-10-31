// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

/// The player under the weather: the cover, title and artist; the line being sung and the next one; a
/// scrubber; and the elapsed time, transport and length. Without synced lyrics the lyric block isn't
/// there and the player closes up. Dragging the scrubber moves the elapsed time and the lyrics with it,
/// and the seek happens on release.
struct NowPlayer: View {
    let media: MediaFeature
    let now: NowPlaying
    let metrics: NowMetrics

    /// Where the scrubber is being dragged to, as a fraction.
    @State private var scrub: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let synced = media.synced {
                lyrics(synced).frame(maxHeight: .infinity)
            } else {
                Color.clear.frame(height: 10)
            }
            controls
        }
        .frame(maxWidth: .infinity, maxHeight: media.synced == nil ? nil : .infinity, alignment: .top)
    }

    // MARK: Title

    private var header: some View {
        HStack(spacing: 10) {
            artwork
            VStack(alignment: .leading, spacing: 1) {
                Text(now.title).deckText(.body).fontWeight(.semibold).lineLimit(1)
                if let artist = now.artist { Text(artist).deckText(.detail).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var artwork: some View {
        Group {
            if let image = media.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Deck.control
            }
        }
        .frame(width: metrics.artwork, height: metrics.artwork)
        .clipShape(RoundedRectangle(cornerRadius: Deck.Radius.control, style: .continuous))
        .accessibilityHidden(true)
    }

    // MARK: Lyrics

    private func lyrics(_ synced: SyncedLyrics) -> some View {
        NowLyrics(
            lyrics: synced, now: now, scrub: scrub.map { $0 * (now.duration ?? 0) }, showsNext: metrics.showsNextLyric,
            small: !metrics.showsNextLyric)
    }

    // MARK: Controls

    private var controls: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = now.duration ?? 0
            let position = scrub.map { $0 * duration } ?? now.position(at: context.date) ?? 0
            VStack(spacing: 0) {
                DeckScrubber(
                    value: duration > 0 ? position / duration : 0, scrub: $scrub, label: "Playback position",
                    spoken: "\(Self.clock(position)) of \(Self.clock(duration))",
                    step: duration > 0 ? 5 / duration : 0, isEnabled: media.hasControls && duration > 0
                ) { fraction in
                    media.seek(to: fraction * duration)
                }
                ZStack {
                    HStack {
                        Text(Self.clock(position)).deckText(.caption).accessibilityHidden(true)
                        Spacer()
                        if duration > 0 { Text(Self.clock(duration)).deckText(.caption).accessibilityHidden(true) }
                    }
                    HStack(spacing: 2) {
                        transport(.previous, "Previous", .previousTrack)
                        transport(
                            now.isPlaying ? .pause : .play, now.isPlaying ? "Pause" : "Play", .togglePlayPause,
                            on: true)
                        transport(.next, "Next", .nextTrack)
                    }
                }
                .frame(height: 30)
            }
        }
    }

    private func transport(_ icon: DeckIcon, _ label: String, _ command: MediaCommand, on: Bool = false) -> some View {
        Button {
            media.send(command)
        } label: {
            DeckIconView(icon)
        }
        .buttonStyle(.deckIcon(on: on))
        .disabled(!media.hasControls)
        .help(label)
        .accessibilityLabel(label)
    }

    /// "1:34" or "1:02:03".
    static func clock(_ seconds: TimeInterval) -> String { formatTime(seconds, roundingUp: false) }
}

/// The line being sung, bold and wrapping to three lines, and the next one under it in one. It keeps
/// its place through gaps, so nothing moves when the words stop, and has its own clock so the player's
/// controls keep their one-second tick. While the scrubber is dragged it shows that moment instead.
struct NowLyrics: View {
    let lyrics: SyncedLyrics
    let now: NowPlaying
    /// Seconds into the track under the scrubber, while it is dragged.
    let scrub: TimeInterval?
    let showsNext: Bool
    let small: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let cursor = lyrics.cursor(at: scrub ?? now.position(at: context.date) ?? 0)
            VStack(alignment: .leading, spacing: 3) {
                Text(cursor.current ?? " ")
                    .deckText(small ? .lyricSmall : .lyric)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                if showsNext, let next = cursor.next {
                    Text(next).deckText(.caption).lineLimit(1).contentTransition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: cursor)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cursor.current ?? "")
            .accessibilityHidden(cursor.current == nil)
        }
    }
}
