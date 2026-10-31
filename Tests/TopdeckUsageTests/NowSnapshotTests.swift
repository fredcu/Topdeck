// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import Testing
import TopdeckCore

@testable import TopdeckFeatures
@testable import TopdeckSurface
@testable import TopdeckUsage

/// Now in the real deck, with sample data and invented lyric text, in each state the boards show and
/// at both sizes. Always checks that each draws; with SNAPSHOT_DIR set, also writes 2x PNGs there as
/// `Now3-<Board>.png`, to compare with docs/design/<Board>.dc.html.
@MainActor
struct NowSnapshotTests {
    /// A notch 196 wide and 37 high, as the boards draw it.
    private static let metrics = NotchMetrics(
        screen: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 37,
        left: CGRect(x: 0, y: 945, width: 658, height: 37), right: CGRect(x: 854, y: 945, width: 658, height: 37))
    private static let wall = Color(red: 0.22, green: 0.26, blue: 0.31)

    // MARK: Sample data

    /// Never asked: the weather is shown, not fetched.
    private final class NoLocator: WeatherLocating {
        func locate() async throws -> (latitude: Double, longitude: Double) { throw WeatherLocationError.unavailable }
        func placeName(latitude: Double, longitude: Double) async -> String? { nil }
    }

    private struct Sample {
        var events = true
        var notes = 5
        var playing = false
        var lyrics = true
        var agent = false
        var timer = false
        var adding = false
        /// The add field as a note, with a colour and a window picked.
        var noteAdd = false
        var weather = true
        var day: Int?
    }

    @MainActor private final class World {
        let calendar: CalendarFeature
        let notes: NotesFeature
        let weather: WeatherFeature
        let media: MediaFeature
        let timer: TimerFeature
        let agents: AgentsFeature
        let model = NowModel()
        let folder = FileManager.default.temporaryDirectory.appending(path: "NowShots-\(UUID().uuidString)")

        init(_ sample: Sample) throws {
            func defaults() -> UserDefaults { UserDefaults(suiteName: "NowShots.\(UUID().uuidString)")! }
            let now = Date.now
            let day = Calendar.current.startOfDay(for: now)
            func at(_ offset: Int, hour: Int, minute: Int = 0) -> Date {
                let date = Calendar.current.date(byAdding: .day, value: offset, to: day)!
                return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: date)!
            }
            let meet = MeetingLink(URL(string: "https://meet.google.com/abc-defg-hij")!)

            calendar = CalendarFeature(eventStore: EventStore(), defaults: defaults())
            var today: [DayEvent] = []
            var range: [DayEvent] = []
            if sample.events {
                today = [
                    DayEvent(
                        id: "sync", title: "Team sync", start: now + 36 * 60, end: now + 96 * 60, meeting: meet),
                    DayEvent(id: "dinner", title: "Dinner booking", start: now + 50 * 60, end: now + 110 * 60),
                ]
                // Dots on the days the boards mark, counted back from the day they show (31 October).
                let dotted = [-27, -26, -25, -24, -17, -11, -5, -4, -3, -2, -1]
                range =
                    dotted.map {
                        DayEvent(id: "dot\($0)", title: "Event", start: at($0, hour: 10), end: at($0, hour: 11))
                    }
                    + [
                        DayEvent(
                            id: "rec", title: "Recreation Day", start: at(2, hour: 0), end: at(2, hour: 23, minute: 59),
                            isAllDay: true),
                        DayEvent(id: "rev", title: "Design review", start: at(3, hour: 15), end: at(3, hour: 16)),
                        DayEvent(
                            id: "parcel", title: "Pick up parcel", start: at(3, hour: 17, minute: 30),
                            end: at(3, hour: 18)),
                        DayEvent(
                            id: "pickup", title: "School pickup", start: at(4, hour: 15, minute: 30),
                            end: at(4, hour: 16)),
                    ] + today
            }
            calendar.show(today: today, range: range)
            if let offset = sample.day { calendar.selectedDay = at(offset, hour: 0) }

            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            notes = NotesFeature(directory: folder, defaults: defaults())
            let titles = [
                "Kitchen measurements", "Gift ideas", "Trip packing list", "Wi-Fi for guests", "Book list",
                "Car service notes", "Holiday dates", "Garden plan", "Meeting prep", "School forms",
            ]
            notes.show(
                notes: titles.prefix(sample.notes).enumerated().map { index, title in
                    var note = Note(id: UUID(), text: title, modified: now - Double(index) * 600)
                    if index == 0 || index == 2 { note.window = .desktop }
                    // The boards' squares: yellow, blue, green, purple, orange, then none.
                    let colors: [NoteColor] = [.yellow, .blue, .green, .purple, .orange]
                    note.color = index < colors.count ? colors[index] : nil
                    return note
                })

            weather = WeatherFeature(
                locator: NoLocator(),
                client: WeatherClient(
                    forecast: { _, _ in throw WeatherLocationError.unavailable },
                    attribution: { throw WeatherLocationError.unavailable }),
                cache: nil)
            weather.show(sample.weather ? Self.forecast(now: now) : nil)

            media = MediaFeature(defaults: defaults())
            if sample.playing {
                let song = NowPlaying(
                    title: "Paper Lanterns", artist: "Ana Vale", isPlaying: true, duration: 238, elapsed: 62,
                    timestamp: now)
                // Invented words, timed to the minute: the first line is the one under way at 1:02.
                let lrc = """
                    [00:48.00]Rooftops count the evenings down
                    [00:58.00]Lanterns wander over the water while the night keeps count of every light along the quiet harbour wall
                    [01:12.00]Somewhere a tide is learning to wait
                    """
                media.show(song, artwork: Self.cover(), synced: sample.lyrics ? SyncedLyrics(lrc: lrc) : nil)
            }

            timer = TimerFeature(defaults: defaults())
            if sample.timer { timer.start(1498) }

            agents = AgentsFeature(defaults: defaults())
            if sample.agent {
                let json = #"""
                    {"session_id":"s-1","hook_event_name":"PermissionRequest","cwd":"/work/Topdeck","tool_name":"Bash",
                     "tool_input":{"command":"git push origin main"}}
                    """#
                agents.received(try AgentRequest.parse(Data(json.utf8), tool: .claude))
            }
            if sample.adding {
                model.begin()
                model.draft = "Call school 3pm"
            }
            if sample.noteAdd {
                model.begin()
                model.draft = "Kitchen measurements"
                model.picked = .note
                model.pick(.orange)
                model.toggle(.desktop)
            }
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        static func forecast(now: Date) -> WeatherSnapshot {
            typealias Sky = (name: String, symbol: String)
            let clear: Sky = ("Clear", "sun.max")
            let partly: Sky = ("Partly Cloudy", "cloud.sun")
            let cloudy: Sky = ("Cloudy", "cloud")
            let rain: Sky = ("Rain", "cloud.rain")
            let calendar = Calendar.current
            let hour = calendar.dateInterval(of: .hour, for: now)!.end
            let codes = [partly, cloudy, rain, rain, cloudy, cloudy]
            let hours = (0..<6).map {
                WeatherSnapshot.Hour(
                    time: hour.addingTimeInterval(TimeInterval($0) * 3600), temperature: 16 - Double($0),
                    condition: codes[$0].name, symbol: codes[$0].symbol)
            }
            let highs: [Double] = [19, 17, 20, 23, 22, 18]
            let lows: [Double] = [9, 8, 9, 11, 10, 9]
            let dayCodes = [partly, cloudy, partly, clear, rain, cloudy]
            let days = (0..<6).map { offset -> WeatherSnapshot.Day in
                let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
                return .init(
                    date: date.addingTimeInterval(12 * 3600), condition: dayCodes[offset].name,
                    symbol: dayCodes[offset].symbol, high: highs[offset],
                    low: lows[offset], rainChance: 20, uv: 3.2)
            }
            let current = WeatherSnapshot.Current(
                temperature: 17.1, apparent: 15, humidity: 62, condition: "Partly Cloudy",
                symbol: "cloud.sun")
            return WeatherSnapshot(
                place: "Hobart", latitude: -42.88, longitude: 147.33,
                forecast: .init(current: current, hours: hours, days: days), fetched: now)
        }

        static func cover() -> NSImage {
            NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                NSColor(red: 0.70, green: 0.23, blue: 0.28, alpha: 1).setFill()
                rect.fill()
                NSColor(red: 0.95, green: 0.76, blue: 0.31, alpha: 1).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 12, dy: 12)).fill()
                NSColor(red: 0.11, green: 0.21, blue: 0.34, alpha: 1).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 25, dy: 25)).fill()
                return true
            }
        }
    }

    // MARK: Drawing

    private func notch(_ world: World, size: CGSize, preferences: NotchPreferences) -> some View {
        let engine = NotchEngine()
        engine.send(.setSpaces(preferences.spaceSet))
        engine.send(.show)
        engine.send(.clicked)
        let content = NotchContent(
            feature: { _ in AnyView(EmptyView()) },
            now: {
                AnyView(
                    NowView(
                        media: world.media, calendar: world.calendar, notes: world.notes, weather: world.weather,
                        model: world.model, openNote: { _ in }))
            },
            badge: { $0 == .agents ? 1 : 0 },
            actions: { space, _ in
                space == .now
                    ? AnyView(NowActions(timer: world.timer, model: world.model, canAdd: true)) : AnyView(EmptyView())
            },
            dropFiles: { _ in false }, openSettings: {},
            slot: { _ in
                AnyView(
                    NowSlot(
                        agent: AgentRequestBar(agents: world.agents, open: { _ in }).map { AnyView($0) },
                        calendar: world.calendar, notes: world.notes, model: world.model))
            })
        return NotchView(engine: engine, metrics: Self.metrics, preferences: preferences, content: content)
    }

    private func preferences(_ size: CGSize) -> NotchPreferences {
        let preferences = NotchPreferences(defaults: UserDefaults(suiteName: "NowShots.\(UUID().uuidString)")!)
        preferences.resizeExpanded(to: size)
        return preferences
    }

    /// One or more decks on the wall, drawn into a bitmap of twice the pixels.
    private func draw(_ name: String, scene: CGSize, decks: [(World, CGSize, CGFloat)]) throws {
        let view = ZStack(alignment: .topLeading) {
            Self.wall
            ForEach(Array(decks.enumerated()), id: \.offset) { _, deck in
                notch(deck.0, size: deck.1, preferences: preferences(deck.1))
                    .frame(width: deck.1.width + 36, height: deck.1.height, alignment: .top)
                    .offset(x: deck.2, y: 0)
            }
        }
        .frame(width: scene.width, height: scene.height)
        .foregroundStyle(Deck.text)
        .environment(\.colorScheme, .dark)
        .transaction { $0.animation = nil }
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: scene)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now + 0.2)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(scene.width) * 2, pixelsHigh: Int(scene.height) * 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = scene
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        if let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(filePath: directory).appending(path: "Now3-\(name).png"))
        }
    }

    nonisolated private static let normal = CGSize(width: 700, height: 430)
    nonisolated private static let smallest = CGSize(width: 620, height: 340)
    private static let scene = CGSize(width: 1080, height: 580)

    /// A deck centered on the board's 1080 wide wall.
    private func single(_ name: String, _ sample: Sample, size: CGSize = NowSnapshotTests.normal) throws {
        let world = try World(sample)
        try draw(name, scene: Self.scene, decks: [(world, size, (Self.scene.width - size.width - 36) / 2)])
    }

    // MARK: The boards

    @Test func nowToday() throws { try single("NowToday", Sample()) }

    @Test func nowPlaying() throws { try single("NowPlaying", Sample(playing: true)) }

    @Test func nowAlert() throws { try single("NowAlert", Sample(playing: true, agent: true, timer: true)) }

    @Test func nowAdd() throws { try single("NowAdd", Sample(adding: true, day: 3)) }

    @Test func noteAdd() throws { try single("NoteAdd", Sample(noteAdd: true)) }

    @Test func nowFree() throws { try single("NowFree", Sample(events: false, notes: 10)) }

    /// Both states at the smallest size, side by side as on the board.
    @Test func nowMin() throws {
        try draw(
            "NowMin", scene: CGSize(width: 1400, height: 470),
            decks: [
                (try World(Sample()), Self.smallest, 12),
                (try World(Sample(playing: true)), Self.smallest, 732),
            ])
    }

    // MARK: The smallest size, and every other state

    /// Each board at the smallest size.
    @Test func everyBoardFitsTheSmallestSize() throws {
        let size = Self.smallest
        try single("NowToday-min", Sample(), size: size)
        try single("NowPlaying-min", Sample(playing: true), size: size)
        try single("NowAlert-min", Sample(playing: true, agent: true, timer: true), size: size)
        try single("NowAdd-min", Sample(adding: true, day: 3), size: size)
        try single("NoteAdd-min", Sample(noteAdd: true), size: size)
        try single("NowFree-min", Sample(events: false, notes: 10), size: size)
    }

    /// The states the boards don't draw, at both sizes. Each is a full render, and the main thread draws them
    /// one at a time among every other test's, so they run only when the pictures are wanted.
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil),
        arguments: [("", NowSnapshotTests.normal), ("-min", NowSnapshotTests.smallest)])
    func everyOtherStateFitsBothSizes(suffix: String, size: CGSize) throws {
        try single("extra-NoLyrics\(suffix)", Sample(playing: true, lyrics: false), size: size)
        try single("extra-Nothing\(suffix)", Sample(events: false, notes: 0, weather: false), size: size)
        try single("extra-PlayingNoWeather\(suffix)", Sample(playing: true, weather: false), size: size)
        try single("extra-NotesOnly\(suffix)", Sample(events: false, notes: 3), size: size)
    }
}
