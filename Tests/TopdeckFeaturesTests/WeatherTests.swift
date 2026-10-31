import AppKit
// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import TopdeckFeatures

private let forecastJSON = """
    {"latitude":-42.88,"longitude":147.33,"utc_offset_seconds":39600,
     "current":{"time":"2026-10-31T18:45","temperature_2m":17.2,"apparent_temperature":14.6,
       "relative_humidity_2m":62,"weather_code":2},
     "hourly":{"time":["2026-10-31T18:00","2026-10-31T19:00","2026-10-31T20:00","2026-10-31T21:00",
       "2026-10-31T22:00","2026-10-31T23:00","2026-11-01T00:00"],
       "temperature_2m":[17,16.4,15.5,14,13,12.4,null],"weather_code":[2,2,3,61,61,3,3]},
     "daily":{"time":["2026-10-31","2026-11-01","2026-11-02","2026-11-03","2026-11-04","2026-11-05"],
       "weather_code":[2,3,0,95,61,2],"temperature_2m_max":[19,17,20,23,22,18],
       "temperature_2m_min":[9,8,9,11,10,9],"precipitation_probability_max":[20,60,0,10,35,null],
       "uv_index_max":[3.4,2,5,6,4,null]}}
    """
private let airJSON = #"{"latitude":-42.88,"longitude":147.33,"current":{"time":"2026-10-31T18:00","us_aqi":24}}"#
private let airMissingJSON = #"{"current":{"time":"2026-10-31T18:00","us_aqi":null}}"#

struct WeatherDataTests {
    @Test func everyWMOCodeHasANameAndASymbol() {
        let codes = [0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 71, 73, 75, 77, 80, 81, 82, 85, 86]
        for code in codes + [95, 96, 99] {
            let condition = WeatherCondition(code: code)
            #expect(!condition.name.isEmpty && !condition.symbol.isEmpty && condition.name != "Cloudy", "\(code)")
        }
        #expect(WeatherCondition(code: 2) == WeatherCondition(code: 2))
        #expect(WeatherCondition(code: 0).symbol == "sun.max" && WeatherCondition(code: 2).name == "Partly Cloudy")
        #expect(WeatherCondition(code: 95).symbol == "cloud.bolt")
        #expect(WeatherCondition(code: 4242).symbol == "cloud", "unknown codes read as cloud")
    }

    @Test func everySymbolExistsOnThisMac() {
        for code in 0...99 {
            #expect(sfSymbolExists(WeatherCondition(code: code).symbol), "\(code)")
        }
        for name in ["thermometer.medium", "arrow.up.arrow.down", "drop", "umbrella", "sun.max", "aqi.medium"] {
            #expect(sfSymbolExists(name), "\(name)")
        }
    }

    @Test func theForecastIsReadWithItsZone() throws {
        let forecast = try WeatherDecoding.forecast(from: Data(forecastJSON.utf8))
        #expect(forecast.current.temperature == 17.2 && forecast.current.apparent == 14.6)
        #expect(forecast.current.humidity == 62 && forecast.current.code == 2)
        #expect(forecast.days.count == 6 && forecast.hours.count == 6, "the hour with no temperature is left out")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 39600)!
        let first = try #require(forecast.hours.first)
        #expect(calendar.component(.hour, from: first.time) == 18 && calendar.component(.day, from: first.time) == 31)
        let today = forecast.days[0]
        #expect(today.high == 19 && today.low == 9 && today.rainChance == 20 && today.uv == 3.4)
        #expect(forecast.days[5].rainChance == nil && forecast.days[5].uv == nil, "nulls are missing, not zero")
        #expect(throws: WeatherDecoding.Failure.self) { try WeatherDecoding.forecast(from: Data("{}".utf8)) }
    }

    @Test func theAirQualityIsAnIntegerOrNothing() throws {
        #expect(try WeatherDecoding.airQuality(from: Data(airJSON.utf8)) == 24)
        #expect(try WeatherDecoding.airQuality(from: Data(airMissingJSON.utf8)) == nil)
        #expect(throws: WeatherDecoding.Failure.self) { try WeatherDecoding.airQuality(from: Data("[]".utf8)) }
    }

    @Test func coordinatesAreRoundedToTwoDecimals() {
        #expect((-42.88213).roundedCoordinate == -42.88 && 147.33999.roundedCoordinate == 147.34)
        let url = WeatherClient.forecastURL(
            latitude: (-42.88213).roundedCoordinate, longitude: 147.3341.roundedCoordinate)
        let text = url.absoluteString
        #expect(text.hasPrefix("https://api.open-meteo.com/v1/forecast?"))
        #expect(text.contains("latitude=-42.88") && text.contains("longitude=147.33") && !text.contains("42.882"))
        #expect(text.contains("current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code"))
        #expect(text.contains("hourly=temperature_2m,weather_code"))
        #expect(
            text.contains(
                "daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,uv_index_max"))
        #expect(text.contains("forecast_days=6") && text.contains("timezone=auto"))
        let air = WeatherClient.airQualityURL(latitude: 1.5, longitude: 2.5).absoluteString
        #expect(
            air.hasPrefix("https://air-quality-api.open-meteo.com/v1/air-quality?") && air.contains("current=us_aqi"))
        #expect(!text.lowercased().contains("key"), "no API key")
    }

    @Test func unitsFollowTheRegionAndShowNoLetter() {
        let celsius = WeatherUnits(fahrenheit: false)
        let fahrenheit = WeatherUnits(fahrenheit: true)
        #expect(celsius.text(17.4) == "17°" && celsius.value(-0.4) == 0)
        #expect(fahrenheit.text(0) == "32°" && fahrenheit.text(100) == "212°" && fahrenheit.text(17) == "63°")
        #expect(WeatherUnits(locale: Locale(identifier: "en_US")).fahrenheit)
        #expect(!WeatherUnits(locale: Locale(identifier: "en_AU")).fahrenheit)
        #expect(!WeatherUnits(locale: Locale(identifier: "en_GB")).fahrenheit)
    }

    @Test func theFiveHoursAndFiveDaysAreTheNextOnes() throws {
        let forecast = try WeatherDecoding.forecast(from: Data(forecastJSON.utf8))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 39600)!
        let now = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 18, minute: 45)))
        let snapshot = WeatherSnapshot(latitude: -42.88, longitude: 147.33, forecast: forecast, fetched: now)
        let hours = snapshot.upcomingHours(after: now)
        #expect(hours.map { calendar.component(.hour, from: $0.time) } == [19, 20, 21, 22, 23])
        let days = snapshot.followingDays(after: now, calendar: calendar)
        #expect(days.count == 5 && days.first?.high == 17 && days.last?.high == 18)
        #expect(snapshot.today(at: now, calendar: calendar)?.high == 19)
    }

    @Test func rangeBarsShareOneScale() {
        func day(_ low: Double, _ high: Double) -> WeatherSnapshot.Day {
            .init(date: .now, code: 0, high: high, low: low, rainChance: nil, uv: nil)
        }
        let bars = WeatherRange.fractions(for: [day(8, 17), day(11, 23), day(9, 18)])
        #expect(bars[0].start == 0 && abs(bars[0].end - 0.6) < 0.001)
        #expect(abs(bars[1].start - 0.2) < 0.001 && bars[1].end == 1)
        #expect(WeatherRange.fractions(for: []).isEmpty)
        #expect(WeatherRange.fractions(for: [day(5, 5)]).count == 1, "no division by zero")
    }
}

@MainActor
final class FakeLocator: WeatherLocating {
    var result: Result<(latitude: Double, longitude: Double), WeatherLocationError> = .success((-42.88213, 147.3341))
    var name: String? = "Hobart"
    private(set) var locates = 0
    private(set) var lookups = 0
    private(set) var named: [(latitude: Double, longitude: Double)] = []
    func locate() async throws -> (latitude: Double, longitude: Double) {
        locates += 1
        return try result.get()
    }
    func placeName(latitude: Double, longitude: Double) async -> String? {
        lookups += 1
        named.append((latitude, longitude))
        return name
    }
}

/// Answers by URL and counts the calls, with a clock the test moves.
final class FakeNetwork: @unchecked Sendable {
    private let lock = NSLock()
    private var _forecast: Result<String, Error> = .success(forecastJSON)
    private var _air: Result<String, Error> = .success(airJSON)
    private var _urls: [URL] = []
    private var _now = Date(timeIntervalSince1970: 1_793_000_000)
    var forecast: Result<String, Error> {
        get { lock.withLock { _forecast } }
        set { lock.withLock { _forecast = newValue } }
    }
    var air: Result<String, Error> {
        get { lock.withLock { _air } }
        set { lock.withLock { _air = newValue } }
    }
    var urls: [URL] { lock.withLock { _urls } }
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
    var client: WeatherClient {
        WeatherClient { [self] url in
            lock.withLock { _urls.append(url) }
            let answer = url.host?.hasPrefix("air-quality") == true ? air : forecast
            return Data(try answer.get().utf8)
        }
    }
}

struct Outage: Error {}

@MainActor
struct WeatherFeatureTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "Weather-\(UUID().uuidString)")

    private func make(
        locator: FakeLocator = FakeLocator(), network: FakeNetwork = FakeNetwork(), cache: Bool = true
    ) -> (WeatherFeature, FakeLocator, FakeNetwork) {
        let feature = WeatherFeature(
            locator: locator, client: network.client, cache: cache ? folder.appending(path: "weather.json") : nil,
            clock: { [network] in network.now })
        return (feature, locator, network)
    }

    @Test func aFailedAttemptWaitsAFullIntervalAndReopeningCannotHammer() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let stale = now.addingTimeInterval(-3 * 3600)
        let interval = WeatherFeature.interval
        #expect(WeatherFeature.shouldFetch(now: now, fetched: stale, lastAttempt: nil), "stale data: fetch on open")
        #expect(WeatherFeature.wait(now: now, fetched: stale, lastAttempt: now) == interval, "not 60 s")
        #expect(!WeatherFeature.shouldFetch(now: now.addingTimeInterval(30), fetched: stale, lastAttempt: now))
        #expect(WeatherFeature.shouldFetch(now: now.addingTimeInterval(60), fetched: stale, lastAttempt: now))
        #expect(!WeatherFeature.shouldFetch(now: now, fetched: now.addingTimeInterval(-60), lastAttempt: nil))
        #expect(WeatherFeature.wait(now: now, fetched: now.addingTimeInterval(-60), lastAttempt: nil) == interval - 60)
    }

    @Test func refreshingStoresTheForecastTheAirAndThePlace() async throws {
        let (feature, locator, network) = make()
        #expect(feature.status == .unavailable && feature.snapshot == nil)
        await feature.refresh()
        let snapshot = try #require(feature.snapshot)
        #expect(feature.status == .ready && snapshot.place == "Hobart" && snapshot.aqi == 24)
        #expect(snapshot.latitude == -42.88 && snapshot.longitude == 147.33)
        #expect(snapshot.forecast?.current.temperature == 17.2 && snapshot.fetched == network.now)
        #expect(network.urls.count == 2 && locator.lookups == 1)
        #expect(
            network.urls.allSatisfy { $0.absoluteString.contains("latitude=-42.88") }, "only the rounded place is sent")
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func thePlaceIsNamedFromTheExactFix() async {
        let locator = FakeLocator()
        locator.result = .success((1.23456, 7.89012))
        let (feature, _, network) = make(locator: locator, cache: false)
        await feature.refresh()
        #expect(
            locator.named.count == 1 && locator.named[0].latitude == 1.23456 && locator.named[0].longitude == 7.89012)
        #expect(network.urls.count == 2 && network.urls.allSatisfy { $0.absoluteString.contains("latitude=1.23") })
        #expect(network.urls.allSatisfy { $0.absoluteString.contains("longitude=7.89") })
    }

    @Test func thePlaceIsNamedOnEveryRefresh() async {
        let (feature, locator, _) = make(cache: false)
        await feature.refresh()
        await feature.refresh()
        #expect(locator.lookups == 2, "named from each fix, not only when the rounded point moves")
        locator.result = .success((-33.87, 151.21))
        locator.name = "Sydney"
        await feature.refresh()
        #expect(locator.lookups == 3 && feature.snapshot?.place == "Sydney")
    }

    @Test func oneFailedCallKeepsTheLastDataAndTheOtherHalfStillShows() async throws {
        let (feature, _, network) = make(cache: false)
        await feature.refresh()
        network.forecast = .failure(Outage())
        network.air = .success(#"{"current":{"us_aqi":57}}"#)
        await feature.refresh()
        #expect(feature.snapshot?.forecast?.current.temperature == 17.2, "the forecast stayed")
        #expect(feature.snapshot?.aqi == 57, "the air quality updated")
        network.air = .failure(Outage())
        network.forecast = .success(forecastJSON.replacingOccurrences(of: "17.2", with: "18.2"))
        await feature.refresh()
        #expect(feature.snapshot?.forecast?.current.temperature == 18.2 && feature.snapshot?.aqi == 57)
    }

    @Test func aMissingAirQualityHidesOnlyThatMetric() async {
        let (feature, _, network) = make(cache: false)
        network.air = .success(airMissingJSON)
        await feature.refresh()
        #expect(feature.status == .ready && feature.snapshot?.aqi == nil)
    }

    @Test func bothCallsFailingKeepsWhatWasShownOrShowsNothing() async {
        let (feature, _, network) = make(cache: false)
        network.forecast = .failure(Outage())
        network.air = .failure(Outage())
        await feature.refresh()
        #expect(feature.status == .unavailable && feature.snapshot == nil)
        network.forecast = .success(forecastJSON)
        await feature.refresh()
        network.forecast = .failure(Outage())
        network.air = .failure(Outage())
        await feature.refresh()
        #expect(feature.status == .ready, "the last good result is shown until replaced")
    }

    @Test func aRefusedLocationIsAPermissionProblem() async {
        let locator = FakeLocator()
        locator.result = .failure(.denied)
        let (feature, _, network) = make(locator: locator, cache: false)
        await feature.refresh()
        #expect(feature.status == .denied && network.urls.isEmpty, "nothing is sent without a place")
        locator.result = .success((1.234, 5.678))
        await feature.refresh()
        #expect(feature.status == .ready, "granting it later works")
        locator.result = .failure(.unavailable)
        await feature.refresh()
        #expect(feature.status == .ready, "no fix this time keeps what there is")
    }

    @Test func theLastResultSurvivesInTheCacheFile() async throws {
        let (feature, _, _) = make()
        await feature.refresh()
        let (second, _, _) = make(locator: FakeLocator(), network: FakeNetwork())
        second.phase = .foreground
        let cached = try #require(second.snapshot)
        #expect(cached == feature.snapshot, "read back, shown at once")
        second.phase = .stopped
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func dataIsStaleAfterHalfAnHour() async {
        let (feature, _, network) = make(cache: false)
        #expect(feature.isStale(at: network.now))
        await feature.refresh()
        #expect(!feature.isStale(at: network.now + 29 * 60))
        #expect(feature.isStale(at: network.now + 30 * 60))
    }

    @Test func itFetchesOnOpeningWithOldDataAndNeverWhileBackground() async {
        let (feature, locator, _) = make(cache: false)
        feature.phase = .background
        try? await Task.sleep(for: .milliseconds(100))
        #expect(locator.locates == 0, "nothing runs in the background")
        feature.phase = .foreground
        #expect(await eventually { feature.snapshot != nil })
        feature.phase = .stopped
        let before = locator.locates
        feature.phase = .foreground
        try? await Task.sleep(for: .milliseconds(100))
        #expect(locator.locates == before, "fresh data is not fetched again on opening")
        feature.phase = .stopped
    }

    @Test func theUserAgentNamesTheApp() {
        #expect(!WeatherClient.appVersion.isEmpty)
    }
}

private func sfSymbolExists(_ name: String) -> Bool {
    NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
}
