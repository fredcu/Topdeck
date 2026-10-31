// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import Testing
import TopdeckCore

@testable import TopdeckFeatures
@testable import TopdeckSurface

/// Plan and Tools in the real deck, with sample data, at the default and the smallest size; and the
/// closed notch of a meeting about to start. With SNAPSHOT_DIR set, also writes PNGs there.
@MainActor
struct PlanToolsSnapshotTests {
    private static let metrics = NotchMetrics(
        screen: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
        left: CGRect(x: 0, y: 950, width: 662, height: 32), right: CGRect(x: 850, y: 950, width: 662, height: 32))

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "PlanTools.\(UUID().uuidString)")! }

    private func plan() -> (CalendarFeature, TasksFeature) {
        let now = Date.now
        let day = Calendar.current.startOfDay(for: now)
        let meet = MeetingLink(URL(string: "https://meet.google.com/abc-defg-hij")!)
        let calendar = CalendarFeature(eventStore: EventStore(), defaults: defaults())
        calendar.show(events: [
            DayEvent(
                id: "1", title: "Design review", start: now + 28 * 60, end: now + 88 * 60, meeting: meet),
            DayEvent(
                id: "2", title: "Pick up from swimming", start: now + 7200, end: now + 9000,
                color: RGB(red: 0.42, green: 0.7, blue: 1), location: "Bondi"),
            DayEvent(
                id: "3", title: "Dinner with Sam", start: now + 16_200, end: now + 21_600,
                color: RGB(red: 0.2, green: 0.84, blue: 0.29), location: "The Grounds"),
        ])
        let tasks = TasksFeature(eventStore: EventStore(), defaults: defaults())
        tasks.show(
            tasks: [
                TaskItem(id: "1", title: "Pay rent", due: day),
                TaskItem(id: "2", title: "Renew domain", due: day + 3 * 86_400),
                TaskItem(id: "3", title: "Review icon", due: day + 4 * 86_400),
                TaskItem(id: "5", title: "交学校表格", due: day + 5 * 86_400),
            ],
            completed: [TaskItem(id: "4", title: "Book dentist", completed: now - 600)])
        return (calendar, tasks)
    }

    private func tools() -> (CaptureFeature, TimerFeature, ShortcutsFeature) {
        let colors = defaults()
        colors.set(["#FFB340", "#3B82F6", "#FC3C44", "#34C759"], forKey: CaptureFeature.colorsKey)
        let timer = TimerFeature(defaults: defaults())
        timer.start(1498)
        timer.keepAwake(for: 4320)
        return (CaptureFeature(defaults: colors), timer, ShortcutsFeature(defaults: defaults()))
    }

    private func draw(_ name: String, events: [NotchEvent], size: CGSize, content: NotchContent) throws {
        let preferences = NotchPreferences(defaults: defaults())
        preferences.resizeExpanded(to: size)
        let engine = NotchEngine()
        engine.send(.setSpaces(preferences.spaceSet))
        events.forEach(engine.send)
        let panel = Self.metrics.panelFrame.size
        let view = NotchView(engine: engine, metrics: Self.metrics, preferences: preferences, content: content)
            .frame(width: panel.width, height: panel.height)
            .background(Color(white: 0.82))
            .transaction { $0.animation = nil }  // the timer's digits have rolled into place
        let image = try #require(NotchSnapshotTests.render(view, size: panel, name: name, settle: true))
        #expect(image.pixelsWide > 0)
    }

    private func content(
        screen: @escaping (SpaceID, Set<FeatureID>) -> AnyView?, accessory: @escaping (SpaceID) -> AnyView,
        actions: @escaping (SpaceID, FeatureID?) -> AnyView
    ) -> NotchContent {
        NotchContent(
            feature: { _ in AnyView(EmptyView()) }, now: { AnyView(EmptyView()) }, badge: { $0 == .agents ? 2 : 0 },
            actions: actions, dropFiles: { _ in false }, openSettings: {}, screen: screen, titleAccessory: accessory)
    }

    @Test(arguments: [
        ("Plan", NotchPreferences.defaultExpandedSize), ("Plan-min", NotchPreferences.minimumExpandedSize),
    ])
    func planFitsItsDeck(name: String, size: CGSize) throws {
        let (calendar, tasks) = plan()
        let content = content(
            screen: { space, _ in space == .plan ? AnyView(PlanScreen(calendar: calendar, tasks: tasks)) : nil },
            accessory: { _ in AnyView(PlanDayChips(calendar: calendar)) },
            actions: { _, _ in AnyView(PlanAddField(calendar: calendar, tasks: tasks)) })
        try draw(name, events: [.show, .selectSpace(.plan)], size: size, content: content)
    }

    @Test(arguments: [
        ("Tools", NotchPreferences.defaultExpandedSize), ("Tools-min", NotchPreferences.minimumExpandedSize),
    ])
    func toolsFitItsDeck(name: String, size: CGSize) throws {
        let (capture, timer, shortcuts) = tools()
        let content = content(
            screen: { space, _ in
                space == .tools
                    ? AnyView(ToolsScreen(capture: capture, timer: timer, shortcuts: shortcuts, sleepDisplays: {}))
                    : nil
            },
            accessory: { _ in AnyView(EmptyView()) }, actions: { _, _ in AnyView(EmptyView()) })
        try draw(name, events: [.show, .selectSpace(.tools)], size: size, content: content)
        timer.allowSleep()
    }

    @Test func aMeetingAboutToStartHasAJoinButton() throws {
        let link = URL(string: "https://meet.google.com/abc-defg-hij")!
        let meeting = Activity(
            feature: .calendar, symbol: "video.fill", title: "Design review starts in", duration: .zero,
            countdown: Date(timeIntervalSinceNow: 4 * 60), meetingLink: link)
        let closed = ClosedContent(meeting)
        #expect(closed.join == link && closed.label == nil && closed.trailingTone == .signal)
        let plain = ClosedContent(
            Activity(
                feature: .timer, symbol: "cup.and.saucer.fill", title: "Awake", duration: .zero,
                countdown: Date(timeIntervalSinceNow: 600)))
        #expect(plain.join == nil && closed.trailingWidth > plain.trailingWidth, "room for the button")
        try draw(
            "Closed", events: [.show, .setOngoing(meeting)], size: NotchPreferences.defaultExpandedSize,
            content: content(
                screen: { _, _ in nil }, accessory: { _ in AnyView(EmptyView()) },
                actions: { _, _ in AnyView(EmptyView()) }))
    }
}
