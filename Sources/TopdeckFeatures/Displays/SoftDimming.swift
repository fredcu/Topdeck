// SPDX-License-Identifier: MIT
import Foundation

/// Dimming the picture of a monitor that doesn't answer DDC: the gamma curve scaled down, never past a
/// floor. The maths, the identity key and the remembered levels; `SystemGamma` carries them to the display.
enum SoftDimming {
    /// The darkest level, so the screen can't be dimmed to black.
    static let floor = 0.15

    /// A display's transfer curve, one table per channel, 0...1.
    struct Curve: Equatable, Sendable {
        var red: [Float]
        var green: [Float]
        var blue: [Float]
    }

    /// `level` held to `floor`...1; a level that isn't a number is no dimming.
    static func clamp(_ level: Double) -> Double { level.isFinite ? min(max(level, floor), 1) : 1 }

    /// `original` scaled to `level`. At 100% it is `original` itself, not multiplied by 1.
    static func table(from original: Curve, level: Double) -> Curve {
        let level = clamp(level)
        guard level < 1 else { return original }
        let scale = Float(level)
        return Curve(
            red: original.red.map { $0 * scale }, green: original.green.map { $0 * scale },
            blue: original.blue.map { $0 * scale })
    }

    /// Names a monitor across reconnects: vendor, product and serial, 0 where macOS doesn't say.
    static func key(vendor: Int64?, product: Int64?, serial: Int64?) -> String {
        "\(vendor ?? 0)-\(product ?? 0)-\(serial ?? 0)"
    }

    /// The level of each monitor in UserDefaults. Only a dimmed monitor is there; 100% is the absence.
    struct Levels {
        static let defaultsKey = "monitors.softDimming"

        let defaults: UserDefaults

        /// 1 for a monitor never dimmed; a stored value is held to the floor.
        func level(for key: String) -> Double {
            guard let stored = (defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double])?[key] else {
                return 1
            }
            return clamp(stored)
        }

        func set(_ level: Double, for key: String) {
            var all = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:]
            let level = clamp(level)
            all[key] = level < 1 ? level : nil
            defaults.set(all, forKey: Self.defaultsKey)
        }
    }
}
