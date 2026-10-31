// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

/// The Now space under its second row: three columns on the black deck, split by hairlines. Left, what
/// is next today and the notes; middle, the month and the days after today; right, the weather, with the
/// player under it while something plays. Each column is there only while its feature is on.
public struct NowView: View {
    let media: MediaFeature?
    let calendar: CalendarFeature?
    let notes: NotesFeature?
    let weather: WeatherFeature?
    let model: NowModel
    let openNote: (Note) -> Void

    public init(
        media: MediaFeature?, calendar: CalendarFeature?, notes: NotesFeature?, weather: WeatherFeature?,
        model: NowModel, openNote: @escaping (Note) -> Void
    ) {
        self.media = media
        self.calendar = calendar
        self.notes = notes
        self.weather = weather
        self.model = model
        self.openNote = openNote
    }

    public var body: some View {
        GeometryReader { proxy in
            let metrics = NowMetrics(size: proxy.size)
            // The minute moves "in 36 min", what has ended, and the day itself.
            TimelineView(.everyMinute) { context in
                HStack(alignment: .top, spacing: Deck.Metric.columnGap) {
                    NowTodayColumn(
                        calendar: calendar, notes: notes, metrics: metrics, now: context.date, openNote: openNote
                    )
                    .frame(width: metrics.left)
                    DeckRule()
                    NowMonthColumn(calendar: calendar, metrics: metrics, now: context.date)
                        .frame(width: metrics.middle)
                    DeckRule()
                    NowWeatherColumn(weather: weather, media: media, metrics: metrics, now: context.date)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            // Clicking away from the add field closes it.
            .contentShape(Rectangle())
            .onTapGesture { if model.isAdding { model.cancel() } }
            .onDisappear { model.cancel() }
        }
    }
}
