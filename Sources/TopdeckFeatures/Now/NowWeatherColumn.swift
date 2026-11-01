// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckSurface

/// The right column. Nothing playing: the place, a large temperature with the condition and today's low
/// and high, four figures, the next five hours and as many of the next five days as the column has room
/// for. Something playing: the same top block with a smaller temperature, and under a hairline the player.
/// Apple's mark and link close the column in both states as a footnote, wherever the data shows.
struct NowWeatherColumn: View {
    let weather: WeatherFeature?
    let media: MediaFeature?
    let metrics: NowMetrics
    let now: Date

    var body: some View {
        let playing = media?.nowPlaying
        VStack(alignment: .leading, spacing: 0) {
            if let weather {
                switch weather.status {
                case .ready:
                    if let snapshot = weather.snapshot {
                        NowWeatherBlock(snapshot: snapshot, metrics: metrics, now: now, playing: playing != nil)
                    }
                case .denied, .unavailable:
                    unavailable(weather.status == .denied, centered: playing == nil)
                }
            }
            if let media, let playing {
                DeckSeparator().padding(.vertical, 9)
                NowPlayer(media: media, now: playing, metrics: metrics)
                Spacer(minLength: 0)
            }
            if let weather, weather.status == .ready {
                // Clear of the deck's resize grip in the corner.
                WeatherAttributionLink(attribution: weather.attribution).padding(.top, 2).padding(.trailing, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await weather?.loadAttribution() }
    }

    @ViewBuilder private func unavailable(_ denied: Bool, centered: Bool) -> some View {
        let content = VStack(spacing: Deck.Metric.gap) {
            Text("Weather unavailable").deckText(.body, color: Deck.tertiary)
            if denied {
                Button("Open Settings") { NSWorkspace.shared.open(.privacySettings("Privacy_LocationServices")) }
                    .buttonStyle(.deck(compact: true))
            }
        }
        if centered {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Apple's combined mark as a footnote, small and faint, trailing, linking to its legal page. Until the
/// mark has loaded, the words stand in as the same link.
struct WeatherAttributionLink: View {
    let attribution: WeatherAttribution?

    private static let legal = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!
    private static let label = "Apple Weather, other data sources"

    var body: some View {
        Link(destination: attribution?.legal ?? Self.legal) {
            if let mark = attribution?.mark {
                AsyncImage(url: mark) { image in
                    image.resizable().scaledToFit().opacity(0.7)
                } placeholder: {
                    text
                }
                .frame(height: 10)
            } else {
                text
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.label)
        .help(Self.label)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var text: some View {
        Text("\u{F8FF} Weather").font(.system(size: 10)).foregroundStyle(Deck.tertiary).opacity(0.7).lineLimit(1)
    }
}

/// The weather itself: place, temperature, figures, and the forecasts.
struct NowWeatherBlock: View {
    let snapshot: WeatherSnapshot
    let metrics: NowMetrics
    let now: Date
    /// Something is playing, so the temperature is smaller and the forecasts give way to the player.
    let playing: Bool

    private let units = WeatherUnits()

    var body: some View {
        if let forecast = snapshot.forecast {
            VStack(alignment: .leading, spacing: 0) {
                placeBlock(forecast.current)
                DeckSeparator().padding(.vertical, playing ? 8 : 10)
                figures(forecast)
                if !playing {
                    DeckSeparator().padding(.vertical, 10)
                    hours
                    // Whatever the column has left under the hours: as many days as fit.
                    GeometryReader { area in daily(metrics.forecastDays(fitting: area.size.height)) }
                }
            }
        }
    }

    // MARK: Place

    private var temperatureStyle: DeckTextStyle {
        if playing { return metrics.largeTemperature ? .temperatureMedium : .temperatureSmall }
        return metrics.largeTemperature ? .temperature : .temperatureMedium
    }

    private var iconSize: CGFloat {
        switch temperatureStyle {
        case .temperature: 36
        case .temperatureMedium: 28
        default: 22
        }
    }

    /// Line 1: the place, the whole width. Line 2: the icon with the temperature, and at the right the
    /// condition over today's low and high.
    private func placeBlock(_ current: WeatherSnapshot.Current) -> some View {
        let today = snapshot.today(at: now)
        return VStack(alignment: .leading, spacing: 4) {
            if let place = snapshot.place {
                Text(place).deckText(.item).lineLimit(1).truncationMode(.tail).help(place)
            }
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: current.symbol)
                        .font(.system(size: iconSize, weight: .regular))
                        .symbolVariant(.fill)
                        .symbolRenderingMode(.multicolor)
                        .accessibilityHidden(true)
                    Text(units.text(current.temperature)).deckText(temperatureStyle).lineLimit(1).fixedSize()
                }
                .fixedSize()
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(current.condition).deckText(.caption).lineLimit(1).truncationMode(.tail)
                    if let today { lowHigh(today) }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.place ?? "Weather"), \(current.condition), \(units.text(current.temperature))")
    }

    /// "↓9° ↑19°": the arrows quiet, the numbers semibold.
    private func lowHigh(_ day: WeatherSnapshot.Day) -> some View {
        HStack(spacing: 3) {
            arrow("arrow.down")
            Text(units.text(day.low)).deckText(.figure).lineLimit(1)
            arrow("arrow.up").padding(.leading, 4)
            Text(units.text(day.high)).deckText(.figure).lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Low and high")
        .accessibilityValue("\(units.text(day.low)) \(units.text(day.high))")
    }

    private func arrow(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 9, weight: .medium)).foregroundStyle(Deck.tertiary)
    }

    // MARK: Figures

    /// Feels like, humidity, rain chance and UV in one row, spread edge to edge.
    private func figures(_ forecast: WeatherSnapshot.Forecast) -> some View {
        let today = snapshot.today(at: now)
        var cells: [(symbol: String, value: String, label: String)] = [
            ("thermometer.medium", units.text(forecast.current.apparent), "Feels like"),
            ("drop", "\(Int(forecast.current.humidity.rounded()))%", "Humidity"),
        ]
        if let rain = today?.rainChance { cells.append(("umbrella", "\(Int(rain.rounded()))%", "Chance of rain")) }
        if let uv = today?.uv { cells.append(("sun.max", "\(Int(uv.rounded()))", "UV index")) }
        return HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                if index > 0 { Spacer(minLength: 4) }
                DeckMetricCell(symbol: cell.symbol, value: cell.value, label: cell.label)
            }
        }
    }

    // MARK: Forecasts
    private var hours: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(snapshot.upcomingHours(after: now), id: \.time) { hour in
                VStack(spacing: 3) {
                    Text(hour.time.formatted(.dateTime.hour())).deckText(.caption).lineLimit(1)
                    Image(systemName: hour.symbol)
                        .font(.system(size: 14))
                        .symbolVariant(.fill)
                        .symbolRenderingMode(.multicolor)
                        .frame(height: 16)
                        .accessibilityHidden(true)
                    Text(units.text(hour.temperature)).deckText(.figure).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(hour.time.formatted(.dateTime.hour())), \(hour.condition), \(units.text(hour.temperature))"
                )
            }
        }
    }

    /// The next `count` days under a hairline; nothing, hairline included, for none.
    @ViewBuilder private func daily(_ count: Int) -> some View {
        if count > 0 { dailyRows(snapshot.followingDays(after: now, count: count)) }
    }

    private func dailyRows(_ days: [WeatherSnapshot.Day]) -> some View {
        let ranges = WeatherRange.fractions(for: days)
        return VStack(alignment: .leading, spacing: 0) {
            DeckSeparator().padding(.top, NowMetrics.forecastLead - 5).padding(.bottom, 4)
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                HStack(spacing: 6) {
                    Text(day.date.formatted(.dateTime.weekday(.abbreviated))).deckText(.caption).lineLimit(1)
                        .frame(width: 30, alignment: .leading)
                    Image(systemName: day.symbol)
                        .font(.system(size: 12))
                        .symbolVariant(.fill)
                        .symbolRenderingMode(.multicolor)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(units.text(day.low)).deckText(.figure, color: Deck.tertiary).lineLimit(1)
                        .frame(width: 26, alignment: .trailing)
                    rangeBar(ranges[index])
                    Text(units.text(day.high)).deckText(.figure).lineLimit(1).frame(width: 26, alignment: .trailing)
                }
                .frame(height: metrics.forecastRow)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(day.date.formatted(.dateTime.weekday(.wide))), \(day.condition), low \(units.text(day.low)), high \(units.text(day.high))"
                )
            }
        }
    }

    private func rangeBar(_ range: (start: Double, end: Double)) -> some View {
        Capsule().fill(Deck.control).frame(height: 4)
            .overlay {
                GeometryReader { track in
                    Capsule()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Deck.Range.cool, location: 0),
                                    .init(color: Deck.Range.mild, location: 0.6),
                                    .init(color: Deck.Range.warm, location: 1),
                                ], startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: max(track.size.width * (range.end - range.start), 4))
                        .offset(x: track.size.width * range.start)
                }
            }
            .accessibilityHidden(true)
    }
}
