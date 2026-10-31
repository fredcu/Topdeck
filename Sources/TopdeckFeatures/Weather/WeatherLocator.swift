// SPDX-License-Identifier: MIT
import CoreLocation
import Foundation

/// Where the Mac is, once, and what the place is called.
@MainActor
public protocol WeatherLocating: AnyObject {
    /// The approximate coordinates. Throws `WeatherLocationError.denied` when the user said no.
    func locate() async throws -> (latitude: Double, longitude: Double)
    /// The locality for coordinates, or nil.
    func placeName(latitude: Double, longitude: Double) async -> String?
}

public enum WeatherLocationError: Error, Equatable {
    /// Location Services is off for Topdeck, or for the Mac.
    case denied
    case unavailable
}

/// Core Location: a one-shot request to about a hundred metres, and the geocoder for the place's name. The
/// system asks on first use.
@MainActor
public final class SystemWeatherLocator: NSObject, WeatherLocating, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<(latitude: Double, longitude: Double), Error>?
    private var authorizing: CheckedContinuation<Void, Never>?

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    public func locate() async throws -> (latitude: Double, longitude: Double) {
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                authorizing = continuation
                manager.requestWhenInUseAuthorization()
            }
        }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: break
        default: throw WeatherLocationError.denied
        }
        guard waiting == nil else { throw WeatherLocationError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            waiting = continuation
            manager.requestLocation()
        }
    }

    public func placeName(latitude: Double, longitude: Double) async -> String? {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
            CLLocation(latitude: latitude, longitude: longitude))
        return placemarks?.first?.locality
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        authorizing?.resume()
        authorizing = nil
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        waiting?.resume(returning: (coordinate.latitude, coordinate.longitude))
        waiting = nil
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        waiting?.resume(throwing: denied ? WeatherLocationError.denied : WeatherLocationError.unavailable)
        waiting = nil
    }
}
