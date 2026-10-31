// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckCore
import TopdeckFeatures
import TopdeckSurface
import TopdeckUsage

/// The Now space: media, the oldest agent waiting, the next event and first task, the timer and
/// Keep Awake. A card appears only when it has something; with nothing the deck shows the date and
/// clock.
struct NowView: View {
    let media: MediaFeature
    let agents: AgentsFeature
    let calendar: CalendarFeature
    let tasks: TasksFeature
    let timer: TimerFeature
    /// Opens a space, for what Now can't do itself.
    let open: (SpaceID) -> Void

    var body: some View {
        let layout = self.layout
        if layout.isEmpty {
            DateAndClock()
        } else {
            VStack(spacing: Deck.Metric.gap) {
                ForEach(Array(layout.rows.enumerated()), id: \.offset) { _, row in
                    DeckWeightedRow(row.count == 2 ? [1.25, 1] : [1]) {
                        ForEach(row, id: \.self) { card in
                            cardView(card)
                        }
                    }
                }
            }
        }
    }

    private var layout: NowLayout {
        NowLayout(
            media: media.nowPlaying != nil, agent: waiting != nil, event: nextEvent != nil, task: firstTask != nil,
            timer: timer.countdown != nil, awake: timer.keepsAwake)
    }

    @ViewBuilder private func cardView(_ card: NowCard) -> some View {
        switch card {
        case .media: MediaCard(media: media)
        case .agent: if let waiting { AgentCard(agents: agents, waiting: waiting, open: open) }
        case .event: EventCard(calendar: calendar, event: nextEvent, task: firstTask)
        case .timers: TimersCard(timer: timer)
        }
    }

    // MARK: What's waiting

    /// The oldest request for an answer, else the session that has waited longest.
    private var waiting: Waiting? {
        if let request = agents.requests.first { return .request(request) }
        let sessions = agents.sessions.filter { $0.state == .waiting }
        return sessions.min { $0.updated < $1.updated }.map(Waiting.session)
    }

    /// The next event that hasn't ended: timed, not declined.
    private var nextEvent: DayEvent? {
        calendar.events.first { !$0.isAllDay && !$0.isDeclined && $0.end > .now }
    }

    private var firstTask: TaskItem? { tasks.tasks.first }
}

/// What the agent card answers.
enum Waiting {
    case request(AgentRequest)
    case session(AgentSession)
}

// MARK: Cards

private struct MediaCard: View {
    let media: MediaFeature

    var body: some View {
        if let now = media.nowPlaying {
            DeckCard {
                // The smallest deck has no height for the big cover and the controls under it, and
                // sometimes none for a lyric line either.
                ViewThatFits(in: .vertical) {
                    column(now, art: 72, spacing: 12, lyrics: .both)
                    column(now, art: 40, spacing: 6, lyrics: .current)
                    column(now, art: 40, spacing: 6, lyrics: nil)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The cover and titles, the lyric lines when there are any, and the controls at the bottom.
    private func column(_ now: NowPlaying, art: CGFloat, spacing: CGFloat, lyrics: LyricsLines.Show?) -> some View {
        VStack(spacing: spacing) {
            HStack(spacing: art > 40 ? 12 : 10) {
                artwork(art)
                titles(now)
                Spacer(minLength: 0)
            }
            if let lyrics, let synced = media.synced { LyricsLines(now: now, lyrics: synced, show: lyrics) }
            Spacer(minLength: 0)
            controls(now)
        }
    }

    private func titles(_ now: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(now.title).deckText(.item).lineLimit(1)
            if let artist = now.artist { Text(artist).deckText(.detail).lineLimit(1) }
        }
    }

    private func artwork(_ side: CGFloat) -> some View {
        Group {
            if let image = media.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Deck.control
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }

    /// The bar, and under it the elapsed time, the transport, and the length.
    private func controls(_ now: NowPlaying) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let position = Self.position(now, at: context.date)
            VStack(spacing: 8) {
                DeckBar(now.duration.map { $0 > 0 ? position / $0 : 0 } ?? 0)
                ZStack {
                    HStack {
                        Text(Self.clock(position)).deckText(.caption)
                        Spacer()
                        if let duration = now.duration { Text(Self.clock(duration)).deckText(.caption) }
                    }
                    HStack(spacing: 18) {
                        transport(.previous, "Previous", .previousTrack)
                        transport(
                            now.isPlaying ? .pause : .play, now.isPlaying ? "Pause" : "Play", .togglePlayPause,
                            on: true)
                        transport(.next, "Next", .nextTrack)
                    }
                }
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

    /// Seconds into the track at `date`, from the last report.
    static func position(_ now: NowPlaying, at date: Date) -> TimeInterval {
        let base = now.elapsed ?? 0
        guard now.isPlaying, let stamp = now.timestamp else { return base }
        let position = base + date.timeIntervalSince(stamp) * now.playbackRate
        return min(max(position, 0), now.duration ?? position)
    }

    /// "1:34" or "1:02:03".
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(max(seconds, 0))
        let (hours, minutes, secs) = (whole / 3600, whole / 60 % 60, whole % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

/// The line being sung and, under it, the next one. It keeps its height through gaps, so nothing
/// moves when the words stop, and has its own clock so the card's controls keep their 1 s tick.
private struct LyricsLines: View {
    let now: NowPlaying
    let lyrics: SyncedLyrics
    let show: Show
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A tall card has room for the next line too.
    enum Show { case both, current }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let cursor = lyrics.cursor(at: now.position(at: context.date) ?? 0)
            VStack(alignment: .leading, spacing: 2) {
                line(cursor.current, .item)
                if show == .both { line(cursor.next, .detail) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: cursor)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cursor.current ?? "")
        }
    }

    /// A blank line still takes a line's height.
    private func line(_ text: String?, _ style: DeckTextStyle) -> some View {
        Text(text ?? " ").deckText(style).lineLimit(1).truncationMode(.tail)
            .contentTransition(.opacity)
    }
}

private struct AgentCard: View {
    let agents: AgentsFeature
    let waiting: Waiting
    let open: (SpaceID) -> Void

    var body: some View {
        DeckCard(.signal) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    DeckIconView(.hand)
                    Text(project).deckText(.body, color: Deck.signal).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: Deck.Metric.gap)
                    Text(detail).deckText(.caption).lineLimit(1)
                }
                .foregroundStyle(Deck.signal)
                Text(summary).deckText(.command).lineLimit(3).truncationMode(.middle)
                Spacer(minLength: 0)
                HStack(spacing: Deck.Metric.gap) { buttons }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
    }

    private var project: String {
        switch waiting {
        case .request(let request): request.project
        case .session(let session): session.project
        }
    }

    /// The tool it wants to use, or that the session waits.
    private var detail: String {
        switch waiting {
        case .request(let request): request.isQuestion ? "Question" : request.toolName
        case .session: "Waiting"
        }
    }

    private var summary: String {
        switch waiting {
        case .request(let request): request.isQuestion ? (request.questions.first?.question ?? "") : request.summary
        case .session(let session): session.detail ?? ""
        }
    }

    /// Allow and Deny for a request; a question is answered in the Agents space, where its choices are.
    @ViewBuilder private var buttons: some View {
        switch waiting {
        case .request(let request) where !request.isQuestion:
            Button("Allow") { agents.answer(request, .allow) }
                .buttonStyle(.deck(.primary, fill: true))
            Button("Deny") { agents.answer(request, .deny) }
                .buttonStyle(.deck(fill: true))
        case .request:
            Button("Answer") { open(.agents) }.buttonStyle(.deck(.accent, fill: true))
        case .session(let session):
            Button("Open") { agents.open(session) }.buttonStyle(.deck(.outline, fill: true))
        }
    }
}

private struct EventCard: View {
    let calendar: CalendarFeature
    let event: DayEvent?
    let task: TaskItem?

    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 10) {
                if let event {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title).deckText(.item).lineLimit(1)
                            Text(
                                "\(event.start.formatted(date: .omitted, time: .shortened)) to \(event.end.formatted(date: .omitted, time: .shortened))"
                            )
                            .deckText(.detail).lineLimit(1)
                        }
                        Spacer(minLength: Deck.Metric.gap)
                        if event.meeting != nil {
                            Button("Join") { calendar.join(event) }.buttonStyle(.deck(.accent))
                        }
                    }
                }
                if event != nil, task != nil {
                    Spacer(minLength: 0)
                    DeckSeparator()
                    Spacer(minLength: 0)
                }
                if let task {
                    HStack {
                        Text(task.title).deckText(.body).lineLimit(1)
                        Spacer(minLength: Deck.Metric.gap)
                        if let due = task.due { Text(Self.due(due)).deckText(.caption) }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private static func due(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? "Today" : date.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct TimersCard: View {
    let timer: TimerFeature

    var body: some View {
        HStack(spacing: Deck.Metric.gap) {
            if let countdown = timer.countdown {
                half("Timer") {
                    if let end = countdown.endsAt {
                        Text(timerInterval: Date.now...max(end, .now), countsDown: true).deckText(.metric)
                    } else {
                        Text(MediaCard.clock(countdown.remaining)).deckText(.metric)
                    }
                }
            }
            if timer.keepsAwake, let until = timer.awakeUntil {
                half("Awake") {
                    if until == .distantFuture {
                        DeckIconView(.moon, size: 26).foregroundStyle(Deck.text)
                    } else {
                        Text(timerInterval: Date.now...max(until, .now), countsDown: true).deckText(.metric)
                    }
                }
            }
        }
    }

    private func half(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 0) {
                Text(label).deckText(.caption)
                Spacer(minLength: 0)
                value().lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Nothing to show: the time, large, and the date under it.
private struct DateAndClock: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 6) {
                Text(context.date.formatted(.dateTime.hour().minute())).deckText(.timer)
                Text(context.date.formatted(.dateTime.day().month(.wide))).deckText(.detail)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        }
    }
}
