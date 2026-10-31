// SPDX-License-Identifier: MIT
import CoreLocation
import Foundation
import WeatherKit

/// Apple's mark and legal page, which must show wherever the data does.
public struct WeatherAttribution: Equatable, Sendable {
    public var mark: URL
    public var legal: URL

    public init(mark: URL, legal: URL) {
        self.mark = mark
        self.legal = legal
    }
}

/// WeatherKit, behind two closures so tests answer without the framework or the network. Only a place
/// rounded to two decimals is passed in. A build without the WeatherKit entitlement gets an error from
/// the framework, which reads as any other failed fetch.
public struct WeatherClient: Sendable {
    /// The forecast for a place.
    public var forecast: @Sendable (_ latitude: Double, _ longitude: Double) async throws -> WeatherSnapshot.Forecast
    public var attribution: @Sendable () async throws -> WeatherAttribution

    public init(
        forecast:
            @escaping @Sendable (_ latitude: Double, _ longitude: Double) async throws -> WeatherSnapshot.Forecast,
        attribution: @escaping @Sendable () async throws -> WeatherAttribution
    ) {
        self.forecast = forecast
        self.attribution = attribution
    }

    /// How many hours and days are kept: the view shows five of each, after today.
    private static let keptHours = 8
    private static let keptDays = 7

    public static func live() -> WeatherClient {
        WeatherClient(
            forecast: { latitude, longitude in
                let weather = try await WeatherService.shared.weather(
                    for: CLLocation(latitude: latitude, longitude: longitude))
                return Self.forecast(from: weather, now: .now)
            },
            attribution: {
                let attribution = try await WeatherService.shared.attribution
                return WeatherAttribution(mark: attribution.combinedMarkDarkURL, legal: attribution.legalPageURL)
            })
    }

    private static func celsius(_ measurement: Measurement<UnitTemperature>) -> Double {
        measurement.converted(to: .celsius).value
    }

    static func forecast(from weather: Weather, now: Date) -> WeatherSnapshot.Forecast {
        let current = weather.currentWeather
        let hours = weather.hourlyForecast.forecast.filter { $0.date > now }.prefix(keptHours).map {
            WeatherSnapshot.Hour(
                time: $0.date, temperature: celsius($0.temperature), condition: $0.condition.description,
                symbol: $0.symbolName)
        }
        let days = weather.dailyForecast.forecast.prefix(keptDays).map {
            WeatherSnapshot.Day(
                // Noon, so any time zone's weekday is the right one.
                date: $0.date.addingTimeInterval(12 * 3600), condition: $0.condition.description,
                symbol: $0.symbolName, high: celsius($0.highTemperature), low: celsius($0.lowTemperature),
                rainChance: $0.precipitationChance * 100, uv: Double($0.uvIndex.value))
        }
        return WeatherSnapshot.Forecast(
            current: .init(
                temperature: celsius(current.temperature), apparent: celsius(current.apparentTemperature),
                humidity: current.humidity * 100, condition: current.condition.description,
                symbol: current.symbolName),
            hours: Array(hours), days: Array(days))
    }
}
