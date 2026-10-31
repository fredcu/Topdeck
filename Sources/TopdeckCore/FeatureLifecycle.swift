// SPDX-License-Identifier: MIT

/// How much work a feature module may do right now. Ordered: a later case allows more work.
public enum FeaturePhase: Comparable, Hashable, Sendable {
    /// Released: no observers, no tasks, no caches.
    case stopped
    /// Enabled but off screen: only cheap, event-driven observers, such as listening for a
    /// track change so it can raise a live activity.
    case background
    /// On screen: full work, such as artwork, visualizers, or camera capture.
    case foreground
}

/// A notch feature module. `FeatureHost` sets `phase` whenever any notch's presentation or detail screen changes,
/// and only when the value actually changes; a module starts and stops its work in `didSet`.
@MainActor
public protocol NotchFeature: AnyObject {
    var id: FeatureID { get }
    var phase: FeaturePhase { get set }
}

/// Owns the feature modules and moves each one through its lifecycle, looking at the notch on
/// every display: a feature runs at the highest phase any notch asks for.
@MainActor
public final class FeatureHost {
    public let features: [any NotchFeature]

    public init(_ features: [any NotchFeature]) {
        self.features = features
    }

    /// Disabled features stay stopped whatever the notches show.
    public func update(notches: [NotchState], enabled: Set<FeatureID>) {
        for feature in features {
            let wanted = notches.map { $0.phase(for: feature.id) }.max() ?? .stopped
            let phase = enabled.contains(feature.id) ? wanted : .stopped
            guard feature.phase != phase else { continue }
            Log.features.debug(
                "\(feature.id.rawValue, privacy: .public): \(String(describing: feature.phase), privacy: .public) → \(String(describing: phase), privacy: .public)"
            )
            let signpostID = Log.signposter.makeSignpostID()
            Log.signposter.withIntervalSignpost(
                "feature phase", id: signpostID, "\(feature.id.rawValue, privacy: .public)"
            ) {
                feature.phase = phase
            }
        }
    }
}
