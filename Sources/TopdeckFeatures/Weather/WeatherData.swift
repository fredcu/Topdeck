// SPDX-License-Identifier: MIT
import Foundation

/// A WMO weather code (Open-Meteo's `weatherCode`) as a name and an SF Symbol: one table for the
/// whole feature. Codes the table doesn't know read as cloud.
public struct WeatherCondition: Equatable, Sendable {
    public let name: String
    /// An SF Symbol that exists on macOS 14.6, the oldest supported.
    public let symbol: String

    public init(code: Int) {
        switch code {
        case 0: self.init("Clear", "sun.max")
        case 1: self.init("Mainly Clear", "sun.max")
        case 2: self.init("Partly Cloudy", "cloud.sun")
        case 3: self.init("Overcast", "cloud")
        case 45, 48: self.init("Fog", "cloud.fog")
        case 51: self.init("Light Drizzle", "cloud.drizzle")
        case 53: self.init("Drizzle", "cloud.drizzle")
        case 55: self.init("Heavy Drizzle", "cloud.drizzle")
        case 56, 57: self.init("Freezing Drizzle", "cloud.sleet")
        case 61: self.init("Light Rain", "cloud.rain")
        case 63: self.init("Rain", "cloud.rain")
        case 65: self.init("Heavy Rain", "cloud.heavyrain")
        case 66, 67: self.init("Freezing Rain", "cloud.sleet")
        case 71: self.init("Light Snow", "cloud.snow")
        case 73: self.init("Snow", "cloud.snow")
        case 75: self.init("Heavy Snow", "cloud.snow")
        case 77: self.init("Snow Grains", "cloud.snow")
        case 80: self.init("Light Showers", "cloud.sun.rain")
        case 81: self.init("Showers", "cloud.sun.rain")
        case 82: self.init("Heavy Showers", "cloud.heavyrain")
        case 85: self.init("Snow Showers", "cloud.snow")
        case 86: self.init("Heavy Snow Showers", "cloud.snow")
        case 95: self.init("Thunderstorm", "cloud.bolt")
        case 96, 99: self.init("Thunderstorm with Hail", "cloud.bolt.rain")
        default: self.init("Cloudy", "cloud")
        }
    }

    private init(_ name: String, _ symbol: String) {
        self.name = name
        self.symbol = symbol
    }
}

/// What the weather feature keeps: the forecast and the air quality, each as the last call that
/// worked, and the place they are for. Temperatures are Celsius; `WeatherUnits` shows them in the
/// system's units.
public struct WeatherSnapshot: Codable, Equatable, Sendable {
    public struct Current: Codable, Equatable, Sendable {
        public var temperature: Double
        public var apparent: Double
        public var humidity: Double
        public var code: Int
    }

    public struct Hour: Codable, Equatable, Sendable {
        /// The hour's start.
        public var time: Date
        public var temperature: Double
        public var code: Int
    }

    public struct Day: Codable, Equatable, Sendable {
        /// Noon of the day, so any time zone's weekday is the right one.
        public var date: Date
        public var code: Int
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
    /// The US air quality index.
    public var aqi: Int?
    /// When a call last worked.
    public var fetched: Date

    public init(
        place: String? = nil, latitude: Double, longitude: Double, forecast: Forecast? = nil, aqi: Int? = nil,
        fetched: Date
    ) {
        self.place = place
        self.latitude = latitude
        self.longitude = longitude
        self.forecast = forecast
        self.aqi = aqi
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

/// Reads Open-Meteo's answers. Times arrive as local ISO strings ("2026-10-31T18:00") with the zone's
/// offset beside them.
public enum WeatherDecoding {
    public struct Failure: Error, Equatable {}

    /// Open-Meteo's names are snake_case; digits stay with their word ("temperature_2m" is temperature2m).
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { keys in
            let name = keys.last!.stringValue
            var out = ""
            var upper = false
            for character in name {
                if character == "_" {
                    upper = true
                    continue
                }
                out += upper && !character.isNumber ? character.uppercased() : String(character)
                upper = false
            }
            return AnyKey(out)
        }
        return decoder
    }()

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private struct Forecast: Decodable {
        struct Current: Decodable {
            var temperature2m: Double
            var apparentTemperature: Double
            var relativeHumidity2m: Double
            var weatherCode: Int
        }
        struct Hourly: Decodable {
            var time: [String]
            var temperature2m: [Double?]
            var weatherCode: [Int?]
        }
        struct Daily: Decodable {
            var time: [String]
            var weatherCode: [Int?]
            var temperature2mMax: [Double?]
            var temperature2mMin: [Double?]
            var precipitationProbabilityMax: [Double?]?
            var uvIndexMax: [Double?]?
        }
        var utcOffsetSeconds: Int?
        var current: Current
        var hourly: Hourly
        var daily: Daily
    }

    private struct Air: Decodable {
        struct Current: Decodable { var usAqi: Double? }
        var current: Current
    }

    public static func forecast(from data: Data) throws -> WeatherSnapshot.Forecast {
        let raw: Forecast
        do { raw = try Self.decoder.decode(Forecast.self, from: data) } catch { throw Failure() }
        let zone = TimeZone(secondsFromGMT: raw.utcOffsetSeconds ?? 0) ?? .current
        let hours = raw.hourly.time.enumerated().compactMap { index, text -> WeatherSnapshot.Hour? in
            guard let time = date(text, in: zone), index < raw.hourly.temperature2m.count,
                let temperature = raw.hourly.temperature2m[index]
            else { return nil }
            return .init(time: time, temperature: temperature, code: raw.hourly.weatherCode.at(index) ?? 0)
        }
        let days = raw.daily.time.enumerated().compactMap { index, text -> WeatherSnapshot.Day? in
            guard let day = date(text + "T12:00", in: zone), let high = raw.daily.temperature2mMax.at(index),
                let low = raw.daily.temperature2mMin.at(index)
            else { return nil }
            return .init(
                date: day, code: raw.daily.weatherCode.at(index) ?? 0, high: high, low: low,
                rainChance: raw.daily.precipitationProbabilityMax?.at(index),
                uv: raw.daily.uvIndexMax?.at(index))
        }
        guard !days.isEmpty else { throw Failure() }
        let current = WeatherSnapshot.Current(
            temperature: raw.current.temperature2m, apparent: raw.current.apparentTemperature,
            humidity: raw.current.relativeHumidity2m, code: raw.current.weatherCode)
        return .init(current: current, hours: hours, days: days)
    }

    /// The air quality index, or nil when the answer has none for this place.
    public static func airQuality(from data: Data) throws -> Int? {
        do {
            return try Self.decoder.decode(Air.self, from: data).current.usAqi.map { Int($0.rounded()) }
        } catch { throw Failure() }
    }

    private static func date(_ text: String, in zone: TimeZone) -> Date? {
        let parts = text.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        guard parts.count >= 4 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(
            from: DateComponents(
                year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts.count > 4 ? parts[4] : 0))
    }
}

extension Array {
    /// The element at `index` when there is one and it isn't null.
    fileprivate func at<Wrapped>(_ index: Int) -> Wrapped? where Element == Wrapped? {
        indices.contains(index) ? self[index] : nil
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
