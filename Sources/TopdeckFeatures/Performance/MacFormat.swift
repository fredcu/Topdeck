// SPDX-License-Identifier: MIT
import Foundation

/// The words and numbers on the Mac page's cards, from the readings. Pure, so each is tested.
enum MacFormat {
    /// "19" for 18.6; a dash when there is no reading.
    static func whole(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))" } ?? "–" }

    /// "36°", from the sensor's degrees.
    static func degrees(_ value: Double?) -> String? { value.map { "\(Int($0.rounded()))°" } }

    /// A byte count as a number and a unit, "156" "GB", with a decimal only under 100.
    static func bytes(_ count: Int64?) -> (value: String, unit: String) {
        guard let count else { return ("–", "") }
        let text = NetworkFeature.bytes(count)
        let parts = text.split(separator: " ")
        return (String(parts.first ?? "–"), parts.count > 1 ? String(parts[1]) : "")
    }

    /// The speed of both directions as one figure in one unit, and each direction in that unit:
    /// ("3.1", "KB/s", "↓2.8  ↑0.3").
    static func traffic(_ rate: Rate?) -> (value: String, unit: String, detail: String) {
        guard let rate else { return ("–", "KB/s", "") }
        let total = NetworkFeature.speed(rate.down + rate.up)
        let divisor: Double =
            switch total.unit {
            case "GB/s": 1_000_000_000
            case "MB/s": 1_000_000
            default: 1000
            }
        func figure(_ bytes: Double) -> String {
            let value = bytes / divisor
            return String(format: value < 9.95 ? "%.1f" : "%.0f", value)
        }
        return (total.value, total.unit, "↓\(figure(rate.down))  ↑\(figure(rate.up))")
    }

    /// "R 81  W 1014 KB/s": the disk's reads and writes in KB/s, below a hundred MB/s.
    static func disk(read: Double?, written: Double?) -> String {
        guard let read, let written else { return "" }
        func kilobytes(_ bytes: Double) -> String { "\(Int((bytes / 1000).rounded()))" }
        return "R \(kilobytes(read))  W \(kilobytes(written)) KB/s"
    }

    /// "19.4 GB", memory counted the way Activity Monitor does.
    static func gigabytes(_ bytes: Double) -> String { String(format: "%.1f GB", bytes / 1_073_741_824) }

    /// "32 GB", the installed memory or the disk's size.
    static func capacity(_ bytes: Int64, memory: Bool) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: memory ? .memory : .file)
    }

    /// "3d 4h", "5h 12m" or "12m".
    static func uptime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 24 * 60 { return "\(minutes / (24 * 60))d \(minutes / 60 % 24)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(max(minutes, 1))m"
    }

    /// "1.4%".
    static func processCPU(_ percent: Double) -> String { String(format: "%.1f%%", percent) }

    /// "2.5 GB" or "980 MB".
    static func processMemory(_ bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
