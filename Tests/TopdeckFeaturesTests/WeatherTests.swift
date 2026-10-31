import AppKit
// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import TopdeckFeatures

private let testNow = Date(timeIntervalSince1970: 1_793_000_000)

/// A forecast in the shape the client produces: Hobart, 17.2 degrees, partly cloudy.
private func sampleForecast(temperature: Double = 17.2) -> WeatherSnapshot.Forecast {
    let hours = (1...6).map {
        WeatherSnapshot.Hour(
            time: testNow.addingTimeInterval(Double($0) * 3600), temperature: 17 - Double($0), condition: "Cloudy",
            symbol: "cloud")
    }
    let highs: [Double] = [19, 17, 20, 23, 22, 18]
    let days = (0..<6).map {
        WeatherSnapshot.Day(
            date: Calendar.current.startOfDay(for: testNow).addingTimeInterval(Double($0) * 86400 + 12 * 3600),
            condition: "Cloudy", symbol: "cloud", high: highs[$0], low: 9, rainChance: 20, uv: 3)
    }
    let current = WeatherSnapshot.Current(
        temperature: temperature, apparent: 14.6, humidity: 62, condition: "Partly Cloudy", symbol: "cloud.sun")
    return .init(current: current, hours: hours, days: days)
}

private let sampleAttribution = WeatherAttribution(
    mark: URL(string: "https://example.com/mark.png")!, legal: URL(string: "https://example.com/legal")!)

struct WeatherDataTests {
    @Test func everySymbolExistsOnThisMac() {
        for name in [
            "thermometer.medium", "arrow.down", "arrow.up", "drop", "umbrella", "sun.max", "cloud.sun", "cloud",
        ] {
            #expect(sfSymbolExists(name), "\(name)")
        }
    }

    @Test func coordinatesAreRoundedToTwoDecimals() {
        #expect((-42.88213).roundedCoordinate == -42.88 && 147.33999.roundedCoordinate == 147.34)
    }

    @Test func anOlderCacheFileFailsToDecode() {
        let old = """
            {"place":"Hobart","latitude":-42.88,"longitude":147.33,"fetched":0,
             "forecast":{"current":{"temperature":17,"apparent":15,"humidity":62,"code":2},"hours":[],"days":[]}}
            """
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WeatherSnapshot.self, from: Data(old.utf8)) }
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

    @Test func theFiveHoursAndFiveDaysAreTheNextOnes() {
        let snapshot = WeatherSnapshot(
            latitude: -42.88, longitude: 147.33, forecast: sampleForecast(), fetched: testNow)
        let hours = snapshot.upcomingHours(after: testNow)
        #expect(hours.count == 5 && hours.first?.time == testNow.addingTimeInterval(3600))
        let days = snapshot.followingDays(after: testNow)
        #expect(days.count == 5 && days.first?.high == 17 && days.last?.high == 18)
        #expect(snapshot.today(at: testNow)?.high == 19)
    }

    @Test func rangeBarsShareOneScale() {
        func day(_ low: Double, _ high: Double) -> WeatherSnapshot.Day {
            .init(
                date: .now, condition: "", symbol: "", high: high, low: low, rainChance: nil, uv: nil)
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

/// Answers the client's calls, counts them, with a clock the test moves.
final class FakeWeather: @unchecked Sendable {
    private let lock = NSLock()
    private var _forecast: Result<WeatherSnapshot.Forecast, Error> = .success(sampleForecast())
    private var _attribution: Result<WeatherAttribution, Error> = .success(sampleAttribution)
    private var _places: [(Double, Double)] = []
    private var _attributionCalls = 0
    private var _now = testNow
    var forecast: Result<WeatherSnapshot.Forecast, Error> {
        get { lock.withLock { _forecast } }
        set { lock.withLock { _forecast = newValue } }
    }
    var attribution: Result<WeatherAttribution, Error> {
        get { lock.withLock { _attribution } }
        set { lock.withLock { _attribution = newValue } }
    }
    /// The places the forecast was asked for.
    var places: [(Double, Double)] { lock.withLock { _places } }
    var attributionCalls: Int { lock.withLock { _attributionCalls } }
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
    var client: WeatherClient {
        WeatherClient(
            forecast: { [self] latitude, longitude in
                lock.withLock { _places.append((latitude, longitude)) }
                return try forecast.get()
            },
            attribution: { [self] in
                lock.withLock { _attributionCalls += 1 }
                return try attribution.get()
            })
    }
}

struct Outage: Error {}

@MainActor
struct WeatherFeatureTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "Weather-\(UUID().uuidString)")

    private func make(
        locator: FakeLocator = FakeLocator(), network: FakeWeather = FakeWeather(), cache: Bool = true
    ) -> (WeatherFeature, FakeLocator, FakeWeather) {
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

    @Test func refreshingStoresTheForecastAndThePlace() async throws {
        let (feature, locator, network) = make()
        #expect(feature.status == .unavailable && feature.snapshot == nil)
        await feature.refresh()
        let snapshot = try #require(feature.snapshot)
        #expect(feature.status == .ready && snapshot.place == "Hobart")
        #expect(snapshot.latitude == -42.88 && snapshot.longitude == 147.33)
        #expect(snapshot.forecast?.current.temperature == 17.2 && snapshot.fetched == network.now)
        #expect(network.places.count == 1 && locator.lookups == 1)
        #expect(network.places[0] == (-42.88, 147.33), "only the rounded place is sent")
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func thePlaceIsNamedFromTheExactFix() async {
        let locator = FakeLocator()
        locator.result = .success((1.23456, 7.89012))
        let (feature, _, network) = make(locator: locator, cache: false)
        await feature.refresh()
        #expect(
            locator.named.count == 1 && locator.named[0].latitude == 1.23456 && locator.named[0].longitude == 7.89012)
        #expect(network.places.count == 1 && network.places[0] == (1.23, 7.89))
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

    @Test func aFailedFetchKeepsTheLastDataOrShowsNothing() async {
        let (feature, _, network) = make(cache: false)
        network.forecast = .failure(Outage())
        await feature.refresh()
        #expect(feature.status == .unavailable && feature.snapshot == nil)
        network.forecast = .success(sampleForecast())
        await feature.refresh()
        network.forecast = .failure(Outage())
        await feature.refresh()
        #expect(feature.status == .ready, "the last good result is shown until replaced")
        #expect(feature.snapshot?.forecast?.current.temperature == 17.2)
        network.forecast = .success(sampleForecast(temperature: 18.2))
        await feature.refresh()
        #expect(feature.snapshot?.forecast?.current.temperature == 18.2)
    }

    @Test func theAttributionIsFetchedOnceAndKept() async {
        let (feature, _, network) = make(cache: false)
        network.attribution = .failure(Outage())
        await feature.loadAttribution()
        #expect(feature.attribution == nil, "a failure is tried again")
        network.attribution = .success(sampleAttribution)
        await feature.loadAttribution()
        await feature.loadAttribution()
        #expect(feature.attribution == sampleAttribution && network.attributionCalls == 2)
    }

    @Test func aRefusedLocationIsAPermissionProblem() async {
        let locator = FakeLocator()
        locator.result = .failure(.denied)
        let (feature, _, network) = make(locator: locator, cache: false)
        await feature.refresh()
        #expect(feature.status == .denied && network.places.isEmpty, "nothing is sent without a place")
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
        let (second, _, _) = make(locator: FakeLocator(), network: FakeWeather())
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
}

private func sfSymbolExists(_ name: String) -> Bool {
    NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
}
