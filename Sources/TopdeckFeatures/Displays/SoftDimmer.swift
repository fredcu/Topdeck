// SPDX-License-Identifier: MIT
import CoreGraphics

/// Carries a dimming level to a display.
@MainActor
protocol SoftDimmer {
    /// Dims `display` to `level` (100% puts its own curve back). False when it can't be dimmed.
    func apply(_ level: Double, to display: CGDirectDisplayID) -> Bool
    /// Puts `display`'s own curve back.
    func restore(_ display: CGDirectDisplayID)
    func restoreAll()
    /// Lets go of the curves of displays that aren't connected any more.
    func keepOnly(_ displays: [CGDirectDisplayID])
}

/// Dims nothing: what a feature has until it's given the real one, so tests never touch a display.
struct NoDimmer: SoftDimmer {
    func apply(_ level: Double, to display: CGDirectDisplayID) -> Bool { false }
    func restore(_ display: CGDirectDisplayID) {}
    func restoreAll() {}
    func keepOnly(_ displays: [CGDirectDisplayID]) {}
}

/// Scales the display's gamma table with Core Graphics. The curve a display had when first dimmed is
/// kept, so the user's calibration is only scaled, and put back at 100% and on quit. Gamma set this
/// way belongs to this process, and macOS restores the ColorSync curve on the next display change, so
/// a crash doesn't leave a screen dimmed.
@MainActor
final class SystemGamma: SoftDimmer {
    private var originals: [CGDirectDisplayID: SoftDimming.Curve] = [:]

    func apply(_ level: Double, to display: CGDirectDisplayID) -> Bool {
        let level = SoftDimming.clamp(level)
        guard let original = originals[display] ?? Self.read(display) else { return false }
        if level >= 1 {
            // Nothing is remembered for a display that was never dimmed, so there is nothing to put back.
            guard originals[display] != nil else { return true }
            originals[display] = nil
            return Self.write(original, to: display)
        }
        // Remembered only once it's written, so a failed first write doesn't leave a curve to restore.
        guard Self.write(SoftDimming.table(from: original, level: level), to: display) else { return false }
        originals[display] = original
        return true
    }

    func restore(_ display: CGDirectDisplayID) {
        guard let original = originals.removeValue(forKey: display) else { return }
        _ = Self.write(original, to: display)
    }

    func restoreAll() {
        for (display, original) in originals { _ = Self.write(original, to: display) }
        originals = [:]
    }

    func keepOnly(_ displays: [CGDirectDisplayID]) {
        originals = originals.filter { displays.contains($0.key) }
    }

    private static func read(_ display: CGDirectDisplayID) -> SoftDimming.Curve? {
        let capacity = CGDisplayGammaTableCapacity(display)
        guard capacity > 0 else { return nil }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &count) == .success, count > 0
        else { return nil }
        return SoftDimming.Curve(
            red: Array(red.prefix(Int(count))), green: Array(green.prefix(Int(count))),
            blue: Array(blue.prefix(Int(count))))
    }

    private static func write(_ curve: SoftDimming.Curve, to display: CGDirectDisplayID) -> Bool {
        CGSetDisplayTransferByTable(display, UInt32(curve.red.count), curve.red, curve.green, curve.blue) == .success
    }
}
