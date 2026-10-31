// SPDX-License-Identifier: MIT
import Foundation
import Observation
import SwiftUI
import TopdeckCore

/// The weather where you are, for Now. Foreground only: it asks where the Mac is, looks the place up
/// and fetches the forecast from WeatherKit when Now opens with data older than half an hour, and
/// again every half hour while Now stays open. The last good result is shown until a newer one replaces
/// it, kept in memory and in a small file in Caches. A failed fetch keeps what was shown. WeatherKit
/// gets the place rounded to two decimals; Apple's geocoder names it from the exact fix.
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
    /// Apple's mark and legal link, fetched once and kept in memory.
    public private(set) var attribution: WeatherAttribution?

    /// How long data is shown before it is fetched again.
    public static let interval: TimeInterval = 30 * 60

    @ObservationIgnored private let locator: any WeatherLocating
    @ObservationIgnored private let client: WeatherClient
    @ObservationIgnored private let cache: URL?
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var loadedCache = false
    @ObservationIgnored private var loadingAttribution = false
    @ObservationIgnored private var lastAttempt: Date?

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

    /// How soon after an attempt, success or not, opening Now may try again.
    static let retryFloor: TimeInterval = 60

    /// Stale data is fetched, unless an attempt was made less than `retryFloor` ago.
    static func shouldFetch(now: Date, fetched: Date?, lastAttempt: Date?) -> Bool {
        let stale = fetched.map { now.timeIntervalSince($0) >= interval } ?? true
        return stale && lastAttempt.map { now.timeIntervalSince($0) >= retryFloor } ?? true
    }

    /// A full interval after the later of the last good fetch and the last attempt.
    static func wait(now: Date, fetched: Date?, lastAttempt: Date?) -> TimeInterval {
        let last = max(fetched ?? .distantPast, lastAttempt ?? .distantPast)
        return last == .distantPast ? interval : max(last.addingTimeInterval(interval).timeIntervalSince(now), 60)
    }

    private func update() {
        loop?.cancel()
        loop = nil
        guard phase == .foreground else { return }
        loadCache()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if Self.shouldFetch(now: clock(), fetched: snapshot?.fetched, lastAttempt: lastAttempt) {
                    lastAttempt = clock()
                    await refresh()
                }
                let wake = Self.wait(now: clock(), fetched: snapshot?.fetched, lastAttempt: lastAttempt)
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

    /// Asks where the Mac is and fetches the forecast.
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
        let client = client
        async let forecast = Self.attempt { try await client.forecast(latitude, longitude) }
        // The exact fix names the place: rounded, a point near a suburb's edge lands in the next one.
        let placeName = await locator.placeName(latitude: here.latitude, longitude: here.longitude)
        let forecastResult = await forecast
        // It failed: what was shown stays.
        guard let forecastResult else { return }
        var next = snapshot ?? WeatherSnapshot(latitude: latitude, longitude: longitude, fetched: .distantPast)
        next.forecast = forecastResult
        next.latitude = latitude
        next.longitude = longitude
        next.place = placeName ?? next.place
        next.fetched = clock()
        snapshot = next
        save(next)
    }

    /// Fetches Apple's mark and link once; a failure is tried again the next time the view asks.
    public func loadAttribution() async {
        guard attribution == nil, !loadingAttribution else { return }
        loadingAttribution = true
        defer { loadingAttribution = false }
        attribution = try? await client.attribution()
    }

    /// The result, or nil when the call threw. Logged once, without the place.
    private static func attempt<T: Sendable>(_ work: @Sendable () async throws -> T) async -> T? {
        do {
            return try await work()
        } catch {
            Log.features.error("Weather didn't refresh: \(error.localizedDescription, privacy: .public)")
            return nil
        }
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
