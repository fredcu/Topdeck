// SPDX-License-Identifier: MIT
// The hex rounding follows capcap's ColorPickerRunner (MIT), Copyright (c) 2026 realskyrin; see
// THIRD_PARTY_NOTICES.md.
import Foundation

/// A picked colour as the hex code designers paste: "#1E90FF".
enum ColorCode {
    /// sRGB components from 0 to 1, clamped, each rounded to the nearest of 256 steps.
    static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// The colour a code names, for its swatch; nil when it isn't "#RRGGBB".
    static func rgb(_ code: String) -> RGB? {
        guard code.count == 7, code.first == "#", let value = UInt32(code.dropFirst(), radix: 16) else { return nil }
        func component(_ shift: UInt32) -> Double { Double((value >> shift) & 0xFF) / 255 }
        return RGB(red: component(16), green: component(8), blue: component(0))
    }
}
