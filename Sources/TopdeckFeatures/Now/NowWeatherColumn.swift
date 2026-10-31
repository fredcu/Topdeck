// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckSurface

/// The right column. Nothing playing: the place, the condition and a large temperature, six figures,
/// the next five hours and the next five days. Something playing: the place with a smaller temperature
/// and the same figures, and under a hairline the player. Open-Meteo's link sits beside its data.
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

/// The weather itself: place, temperature, figures, and the forecasts.
struct NowWeatherBlock: View {
    let snapshot: WeatherSnapshot
    let metrics: NowMetrics
    let now: Date
    /// Something is playing, so the temperature is smaller and the forecasts give way to the player.
    let playing: Bool

    private let units = WeatherUnits()
    private static let site = URL(string: "https://open-meteo.com/")!

    var body: some View {
        if let forecast = snapshot.forecast {
            // The days go first when the column is tall enough for them; the smallest deck has hours only.
            ViewThatFits(in: .vertical) {
                if metrics.showsDailyForecast && !playing { content(forecast, daily: true) }
                content(forecast, daily: false)
            }
        }
    }

    private func content(_ forecast: WeatherSnapshot.Forecast, daily showsDaily: Bool) -> some View {
        let condition = WeatherCondition(code: forecast.current.code)
        return VStack(alignment: .leading, spacing: 0) {
            placeRow(forecast.current, condition: condition)
            if playing {
                Color.clear.frame(height: 8)
            } else {
                DeckSeparator().padding(.vertical, 10)
            }
            figures(forecast)
            if playing {
                attribution.frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 4)
            } else {
                DeckSeparator().padding(.vertical, 10)
                hours
                if showsDaily { daily }
                Spacer(minLength: 0)
                attribution.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Place

    private var temperatureStyle: DeckTextStyle {
        if playing { return metrics.showsDailyForecast ? .temperatureMedium : .temperatureSmall }
        return metrics.showsDailyForecast ? .temperature : .temperatureMedium
    }

    private var iconSize: CGFloat {
        switch temperatureStyle {
        case .temperature: 36
        case .temperatureMedium: 28
        default: 22
        }
    }

    private func placeRow(_ current: WeatherSnapshot.Current, condition: WeatherCondition) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                if let place = snapshot.place { Text(place).deckText(.item).lineLimit(1) }
                if !playing { Text(condition.name).deckText(.caption).lineLimit(1) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: condition.symbol)
                    .font(.system(size: iconSize, weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Deck.text)
                    .accessibilityHidden(true)
                Text(units.text(current.temperature)).deckText(temperatureStyle).lineLimit(1).fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(snapshot.place ?? "Weather"), \(condition.name), \(units.text(current.temperature))")
    }

    // MARK: Figures

    private func figures(_ forecast: WeatherSnapshot.Forecast) -> some View {
        let today = snapshot.today(at: now)
        var cells: [(symbol: String, value: String, label: String)] = [
            ("thermometer.medium", units.text(forecast.current.apparent), "Feels like")
        ]
        if let today {
            cells.append(("arrow.up.arrow.down", "\(units.text(today.low)) \(units.text(today.high))", "Low and high"))
        }
        cells.append(("drop", "\(Int(forecast.current.humidity.rounded()))%", "Humidity"))
        if let rain = today?.rainChance { cells.append(("umbrella", "\(Int(rain.rounded()))%", "Chance of rain")) }
        if let uv = today?.uv { cells.append(("sun.max", "\(Int(uv.rounded()))", "UV index")) }
        if let aqi = snapshot.aqi {
            cells.append(("aqi.medium", "\(aqi)", "Air quality index"))
        }
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .leading), count: 3),
            alignment: .leading, spacing: 6
        ) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
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
                    Image(systemName: WeatherCondition(code: hour.code).symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(Deck.secondary)
                        .frame(height: 16)
                        .accessibilityHidden(true)
                    Text(units.text(hour.temperature)).deckText(.figure).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(hour.time.formatted(.dateTime.hour())), \(WeatherCondition(code: hour.code).name), \(units.text(hour.temperature))"
                )
            }
        }
    }

    private var daily: some View {
        let days = snapshot.followingDays(after: now)
        let ranges = WeatherRange.fractions(for: days)
        return VStack(alignment: .leading, spacing: 0) {
            DeckSeparator().padding(.top, 10).padding(.bottom, 4)
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                let condition = WeatherCondition(code: day.code)
                HStack(spacing: 6) {
                    Text(day.date.formatted(.dateTime.weekday(.abbreviated))).deckText(.caption).lineLimit(1)
                        .frame(width: 30, alignment: .leading)
                    Image(systemName: condition.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(Deck.secondary)
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
                    "\(day.date.formatted(.dateTime.weekday(.wide))), \(condition.name), low \(units.text(day.low)), high \(units.text(day.high))"
                )
            }
        }
    }

    private func rangeBar(_ range: (start: Double, end: Double)) -> some View {
        Capsule().fill(Deck.control).frame(height: 4)
            .overlay {
                GeometryReader { track in
                    Capsule().fill(Deck.secondary)
                        .frame(width: max(track.size.width * (range.end - range.start), 4))
                        .offset(x: track.size.width * range.start)
                }
            }
            .accessibilityHidden(true)
    }

    private var attribution: some View {
        Link(destination: Self.site) { Text("Open-Meteo").deckText(.caption) }
            .buttonStyle(.plain)
            .help("Weather data by Open-Meteo.com")
    }
}
