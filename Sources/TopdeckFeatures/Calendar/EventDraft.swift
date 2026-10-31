// SPDX-License-Identifier: MIT
import Foundation

/// Short, human due dates: "Today 9:00 AM", "Tomorrow", "Friday", "3 Jun".
public enum DueLabel {
    public static func text(for due: Date, hasTime: Bool, now: Date = .now, calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let offset = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: due)).day ?? 0
        let day: String =
            switch offset {
            case 0: "Today"
            case 1: "Tomorrow"
            case -1: "Yesterday"
            case 2..<7: due.formatted(.dateTime.weekday(.wide))
            default:
                calendar.component(.year, from: due) == calendar.component(.year, from: now)
                    ? due.formatted(.dateTime.day().month(.abbreviated))
                    : due.formatted(.dateTime.day().month(.abbreviated).year())
            }
        return hasTime ? "\(day) \(due.formatted(date: .omitted, time: .shortened))" : day
    }
}

/// An event typed into Now's add field: "Lunch with Sam tomorrow 1pm for 90 min".
public struct EventDraft: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var duration: TimeInterval
    public var isAllDay: Bool

    private static let durationPattern =
        #"\bfor\s+(\d+(?:\.\d+)?)\s*(h|hr|hrs|hour|hours|m|min|mins|minute|minutes)\b"#

    /// A phrase that is only a time of day: "3pm", "at 15:30", "noon".
    private static let timeOnlyPattern =
        #"^\s*(at\s+)?(\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.)?|noon|midnight)\s*$"#

    /// Nil when there's no date or time in the text: an event needs to know when it happens. With a
    /// `day`, a time that names no day of its own falls on that day, and text with no date at all
    /// becomes an all-day event on it.
    public static func parse(
        _ text: String, on day: Date? = nil, defaultDuration: TimeInterval = 3600, calendar: Calendar = .current
    ) -> EventDraft? {
        var rest = text
        var duration: TimeInterval?
        if let match = rest.range(of: durationPattern, options: [.regularExpression, .caseInsensitive]) {
            let phrase = rest[match].lowercased()
            let digits = phrase.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }
            if let amount = Double(digits) {
                let unit = phrase.drop { !$0.isLetter }.dropFirst(3).drop { !$0.isLetter }
                duration = unit.hasPrefix("h") ? amount * 3600 : amount * 60
            }
            rest.replaceSubrange(match, with: " ")
        }
        let string = rest as NSString
        guard
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
            let match = detector.firstMatch(in: rest, options: [], range: NSRange(location: 0, length: string.length)),
            let date = match.date
        else {
            guard let day else { return nil }
            let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty
                ? nil
                : EventDraft(title: title, start: calendar.startOfDay(for: day), duration: 86_400, isAllDay: true)
        }
        let phrase = string.substring(with: match.range)
        let timePattern = #"\d\s*(am|pm|a\.m\.|p\.m\.)|\d:\d\d|\b(noon|midnight|tonight)\b|\bat\s+\d"#
        let hasTime = phrase.range(of: timePattern, options: [.regularExpression, .caseInsensitive]) != nil
        rest = string.replacingCharacters(in: match.range, with: " ")
        var titleWords = rest.split(whereSeparator: \.isWhitespace).map(String.init)
        let dangling: Set<String> = ["at", "on", "from", "in", "@", "-", ",", "–"]
        while let last = titleWords.last, dangling.contains(last.lowercased()) { titleWords.removeLast() }
        let title = titleWords.joined(separator: " ")
        let detected = match.duration > 0 ? match.duration : nil
        var start = hasTime ? date : calendar.startOfDay(for: date)
        if let day, hasTime, phrase.range(of: timeOnlyPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            let clock = calendar.dateComponents([.hour, .minute], from: date)
            start =
                calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: 0, of: day) ?? start
        }
        return EventDraft(
            title: title.isEmpty ? "New Event" : title, start: start,
            duration: hasTime ? (duration ?? detected ?? defaultDuration) : 86_400, isAllDay: !hasTime)
    }
}
