// SPDX-License-Identifier: MIT
import Foundation
import Observation
import SwiftUI
import TopdeckCore

/// The weather where you are, for Now. Foreground only: it asks where the Mac is, looks the place up
/// and fetches the forecast and the air quality when Now opens with data older than half an hour, and
/// again every half hour while Now stays open. The last good result is shown until a newer one replaces
/// it, kept in memory and in a small file in Caches. One call failing keeps what the other brought.
/// Only the place, rounded to two decimals, leaves the Mac, for Open-Meteo.
@MainActor
@Observable
public final class WeatherFeature: NotchFeature {
    public let id = FeatureID.weather
    public var phase: FeaturePhase = .stopped {
        didSet {
            guard phase != oldValue else { return }
            update()
        }
    }
    /// The last good result.
    public private(set) var snapshot: WeatherSnapshot?
    /// Location Services said no, so there is nothing to show until the user changes it.
    public private(set) var isDenied = false
    /// A call is in flight.
    public private(set) var isRefreshing = false

    /// How long data is shown before it is fetched again.
    public static let interval: TimeInterval = 30 * 60

    @ObservationIgnored private let locator: any WeatherLocating
    @ObservationIgnored private let client: WeatherClient
    @ObservationIgnored private let cache: URL?
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var loadedCache = false

    /// `cache` is the JSON file; nil keeps nothing on disk.
    public init(
        locator: any WeatherLocating, client: WeatherClient = .live(), cache: URL? = WeatherFeature.defaultCache,
        clock: @escaping @Sendable () -> Date = { .now }
    ) {
        self.locator = locator
        self.client = client
        self.cache = cache
        self.clock = clock
    }

    public static var defaultCache: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "Topdeck", directoryHint: .isDirectory).appending(path: "weather.json")
    }

    /// What the column says: the weather, or why there is none.
    public enum Status: Equatable, Sendable {
        case ready
        /// No data, and the reason is the user's choice: Open Settings is the fix.
        case denied
        case unavailable
    }

    public var status: Status {
        if isDenied { return .denied }
        return snapshot?.hasData == true ? .ready : .unavailable
    }

    /// The data is old enough to fetch again.
    public func isStale(at now: Date = .now) -> Bool {
        guard let fetched = snapshot?.fetched else { return true }
        return now.timeIntervalSince(fetched) >= Self.interval
    }

    private func update() {
        loop?.cancel()
        loop = nil
        guard phase == .foreground else { return }
        loadCache()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if isStale(at: clock()) { await refresh() }
                let fetched = snapshot?.fetched ?? clock()
                // Without data the next try is in half an hour too, so a failure doesn't hammer the service.
                let wake = max(fetched.addingTimeInterval(Self.interval).timeIntervalSince(clock()), 60)
                do { try await Task.sleep(for: .seconds(wake)) } catch { return }
            }
        }
    }

    private func loadCache() {
        guard !loadedCache else { return }
        loadedCache = true
        guard snapshot == nil, let cache, let data = try? Data(contentsOf: cache),
            let stored = try? JSONDecoder().decode(WeatherSnapshot.self, from: data)
        else { return }
        snapshot = stored
    }

    /// Asks where the Mac is and fetches the forecast and the air quality, which succeed or fail apart.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let here: (latitude: Double, longitude: Double)
        do {
            here = try await locator.locate()
        } catch {
            // An error that isn't a refusal (no fix yet) leaves what is shown as it was.
            isDenied = (error as? WeatherLocationError) == .denied
            return
        }
        isDenied = false
        let latitude = here.latitude.roundedCoordinate
        let longitude = here.longitude.roundedCoordinate
        var next =
            snapshot ?? WeatherSnapshot(latitude: latitude, longitude: longitude, fetched: .distantPast)
        let moved = next.latitude != latitude || next.longitude != longitude
        let client = client
        async let forecast = Self.attempt { try await client.forecast(latitude: latitude, longitude: longitude) }
        async let air = Self.attempt { try await client.airQuality(latitude: latitude, longitude: longitude) }
        var name = next.place
        if moved || name == nil { name = await locator.placeName(latitude: latitude, longitude: longitude) }
        let (forecastResult, airResult) = await (forecast, air)
        var worked = false
        if let forecastResult {
            next.forecast = forecastResult
            worked = true
        }
        if let airResult {
            next.aqi = airResult
            worked = true
        }
        next.latitude = latitude
        next.longitude = longitude
        next.place = name
        // Neither call worked: what was shown stays.
        guard worked else { return }
        next.fetched = clock()
        snapshot = next
        save(next)
    }

    /// The result, or nil when the call threw. A call can succeed with nothing (no AQI), which the
    /// double optional tells apart.
    private static func attempt<T: Sendable>(_ work: @Sendable () async throws -> T) async -> T? {
        try? await work()
    }

    private func save(_ snapshot: WeatherSnapshot) {
        guard let cache else { return }
        try? FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: cache, options: .atomic)
    }

    /// Shows a snapshot as if it had been fetched. For tests and snapshots only.
    func show(_ snapshot: WeatherSnapshot?, denied: Bool = false) {
        self.snapshot = snapshot
        isDenied = denied
    }
}
