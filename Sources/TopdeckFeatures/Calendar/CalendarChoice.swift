// SPDX-License-Identifier: MIT
import EventKit
import SwiftUI

/// One of the Mac's event calendars, copied out of EventKit.
struct CalendarInfo: Identifiable, Hashable, Sendable {
    /// What a calendar's account is, in the order the settings list shows them.
    enum SourceKind: Int, Sendable {
        case local, iCloud, calDAV, exchange, subscribed, birthdays

        init(_ type: EKSourceType) {
            switch type {
            case .local: self = .local
            case .mobileMe: self = .iCloud
            case .calDAV: self = .calDAV
            case .exchange: self = .exchange
            case .subscribed: self = .subscribed
            case .birthdays: self = .birthdays
            @unknown default: self = .calDAV
            }
        }
    }

    var id: String
    var title: String
    var color: RGB?
    /// The account the calendar belongs to: two accounts may share a title.
    var sourceID: String
    var sourceTitle: String
    var sourceKind: SourceKind

    init(_ calendar: EKCalendar) {
        self.init(
            id: calendar.calendarIdentifier, title: calendar.title, color: RGB(calendar.cgColor),
            sourceID: calendar.source?.sourceIdentifier, sourceTitle: calendar.source?.title ?? "Other",
            sourceKind: calendar.source.map { SourceKind($0.sourceType) } ?? .local)
    }

    init(
        id: String, title: String, color: RGB? = nil, sourceID: String? = nil, sourceTitle: String,
        sourceKind: SourceKind
    ) {
        self.id = id
        self.title = title
        self.color = color
        self.sourceID = sourceID ?? sourceTitle
        self.sourceTitle = sourceTitle
        self.sourceKind = sourceKind
    }
}

/// The calendars of one account, as the settings list shows them.
struct CalendarGroup: Identifiable, Equatable {
    var id: String
    var title: String
    var calendars: [CalendarInfo]
}

/// Which calendars Topdeck reads. What is stored is the hidden ones, so a calendar added later shows.
enum CalendarChoice {
    /// The identifiers to read events from: every calendar not hidden. Empty when all are hidden,
    /// which means no events, not "all calendars".
    static func visibleIDs(_ calendars: [CalendarInfo], hidden: Set<String>) -> [String] {
        calendars.map(\.id).filter { !hidden.contains($0) }
    }

    /// The settings list: accounts by kind (local, iCloud, other accounts, subscribed, birthdays) then
    /// name, calendars by title.
    static func groups(_ calendars: [CalendarInfo]) -> [CalendarGroup] {
        Dictionary(grouping: calendars, by: \.sourceID)
            .map { id, members in
                CalendarGroup(
                    id: id, title: members[0].sourceTitle,
                    calendars: members.sorted { ($0.title.lowercased(), $0.id) < ($1.title.lowercased(), $1.id) })
            }
            .sorted { lhs, rhs in
                let (l, r) = (lhs.calendars[0], rhs.calendars[0])
                return (l.sourceKind.rawValue, l.sourceTitle.lowercased(), lhs.id)
                    < (r.sourceKind.rawValue, r.sourceTitle.lowercased(), rhs.id)
            }
    }
}

/// The Mac's calendars in groups, each a checkbox with the calendar's colour.
struct CalendarChoiceView: View {
    let groups: [CalendarGroup]
    let isVisible: (String) -> Bool
    let setVisible: (String, Bool) -> Void

    var body: some View {
        ForEach(groups) { group in
            Section(group.title) {
                ForEach(group.calendars) { calendar in
                    Toggle(
                        isOn: Binding(
                            get: { isVisible(calendar.id) }, set: { setVisible(calendar.id, $0) })
                    ) {
                        Label {
                            Text(calendar.title)
                        } icon: {
                            Circle().fill(calendar.color?.color ?? .secondary).frame(width: 9, height: 9)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("\(calendar.title), \(group.title)")
                }
            }
        }
    }
}
