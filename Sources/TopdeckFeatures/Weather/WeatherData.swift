// SPDX-License-Identifier: MIT
import Foundation

/// What the weather feature keeps: the last forecast that arrived and the place it is for. Temperatures
/// are Celsius; `WeatherUnits` shows them in the system's units. Condition names and symbols come from
/// WeatherKit as they are. A cache file from an older shape fails to decode and is ignored.
public struct WeatherSnapshot: Codable, Equatable, Sendable {
    public struct Current: Codable, Equatable, Sendable {
        public var temperature: Double
        public var apparent: Double
        public var humidity: Double
        /// WeatherKit's localized condition, such as "Partly Cloudy".
        public var condition: String
        public var symbol: String
    }

    public struct Hour: Codable, Equatable, Sendable {
        /// The hour's start.
        public var time: Date
        public var temperature: Double
        public var condition: String
        public var symbol: String
    }

    public struct Day: Codable, Equatable, Sendable {
        /// Noon of the day, so any time zone's weekday is the right one.
        public var date: Date
        public var condition: String
        public var symbol: String
        public var high: Double
        public var low: Double
        public var rainChance: Double?
        public var uv: Double?
    }

    public struct Forecast: Codable, Equatable, Sendable {
        public var current: Current
        public var hours: [Hour]
        public var days: [Day]
    }

    /// The locality, when the geocoder named one.
    public var place: String?
    /// Rounded to two decimals, as sent.
    public var latitude: Double
    public var longitude: Double
    public var forecast: Forecast?
    /// When the forecast last arrived.
    public var fetched: Date

    public init(
        place: String? = nil, latitude: Double, longitude: Double, forecast: Forecast? = nil, fetched: Date
    ) {
        self.place = place
        self.latitude = latitude
        self.longitude = longitude
        self.forecast = forecast
        self.fetched = fetched
    }

    /// Whether there is anything to show.
    public var hasData: Bool { forecast != nil }

    /// The next `count` hours that haven't started yet.
    public func upcomingHours(after now: Date, count: Int = 5) -> [Hour] {
        Array((forecast?.hours ?? []).filter { $0.time > now }.prefix(count))
    }

    /// The `count` days after today.
    public func followingDays(after now: Date, count: Int = 5, calendar: Calendar = .current) -> [Day] {
        Array(
            (forecast?.days ?? []).filter { !calendar.isDate($0.date, inSameDayAs: now) && $0.date > now }.prefix(count)
        )
    }

    /// Today's entry.
    public func today(at now: Date, calendar: Calendar = .current) -> Day? {
        forecast?.days.first { calendar.isDate($0.date, inSameDayAs: now) } ?? forecast?.days.first
    }
}

/// Celsius or Fahrenheit, from the system's region. Shown as a bare degree sign.
public struct WeatherUnits: Equatable, Sendable {
    public var fahrenheit: Bool

    public init(fahrenheit: Bool) { self.fahrenheit = fahrenheit }

    public init(locale: Locale = .current) { self.init(fahrenheit: locale.measurementSystem == .us) }

    /// "17°" for 17 degrees Celsius, or "63°" in Fahrenheit.
    public func text(_ celsius: Double) -> String { "\(value(celsius))°" }

    public func value(_ celsius: Double) -> Int {
        Int((fahrenheit ? celsius * 9 / 5 + 32 : celsius).rounded())
    }
}

/// The five days' range bars share one scale, so a bar's place and length compare across days.
public enum WeatherRange {
    /// Each day's `(start, end)` as fractions of the lowest low to the highest high.
    public static func fractions(for days: [WeatherSnapshot.Day]) -> [(start: Double, end: Double)] {
        guard let low = days.map(\.low).min(), let high = days.map(\.high).max() else { return [] }
        let span = max(high - low, 0.1)
        return days.map { ((($0.low - low) / span), (($0.high - low) / span)) }
    }
}

extension Double {
    /// A coordinate rounded to two decimals, about a kilometre: all that is ever sent.
    public var roundedCoordinate: Double { (self * 100).rounded() / 100 }
}
