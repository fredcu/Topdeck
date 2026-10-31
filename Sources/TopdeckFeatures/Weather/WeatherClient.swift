// SPDX-License-Identifier: MIT
import Foundation

/// Open-Meteo's forecast and air quality calls (open-meteo.com, CC BY 4.0): no key, and only a place
/// rounded to two decimals goes out. The network is a closure, so tests answer without one.
public struct WeatherClient: Sendable {
    /// Gets a URL's body; throws for anything but a success.
    public var fetch: @Sendable (URL) async throws -> Data

    public init(fetch: @escaping @Sendable (URL) async throws -> Data) { self.fetch = fetch }

    public struct Failure: Error, Equatable { public var status: Int }

    /// The real thing, with a plain `Topdeck/<version>` User-Agent.
    public static func live(version: String = Self.appVersion) -> WeatherClient {
        let session = URLSession(configuration: .ephemeral)
        return WeatherClient { url in
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("Topdeck/\(version)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw Failure(status: status) }
            return data
        }
    }

    public static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    public static func forecastURL(latitude: Double, longitude: Double) -> URL {
        url(
            "https://api.open-meteo.com/v1/forecast",
            [
                ("latitude", "\(latitude)"), ("longitude", "\(longitude)"),
                ("current", "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code"),
                ("hourly", "temperature_2m,weather_code"),
                (
                    "daily",
                    "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,uv_index_max"
                ),
                ("forecast_days", "6"), ("timezone", "auto"),
            ])
    }

    public static func airQualityURL(latitude: Double, longitude: Double) -> URL {
        url(
            "https://air-quality-api.open-meteo.com/v1/air-quality",
            [("latitude", "\(latitude)"), ("longitude", "\(longitude)"), ("current", "us_aqi")])
    }

    private static func url(_ base: String, _ items: [(String, String)]) -> URL {
        var parts = URLComponents(string: base)!
        parts.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return parts.url!
    }

    public func forecast(latitude: Double, longitude: Double) async throws -> WeatherSnapshot.Forecast {
        try WeatherDecoding.forecast(from: await fetch(Self.forecastURL(latitude: latitude, longitude: longitude)))
    }

    /// The US air quality index; nil when Open-Meteo has none for the place.
    public func airQuality(latitude: Double, longitude: Double) async throws -> Int? {
        try WeatherDecoding.airQuality(from: await fetch(Self.airQualityURL(latitude: latitude, longitude: longitude)))
    }
}
