// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckCore
import TopdeckFeatures
import TopdeckMixer
import TopdeckSurface
import TopdeckUsage

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = NotchPreferences()
    private let usage = UsageFeature()
    private let agents = AgentsFeature()
    /// The Sound tab: devices, and every app's volume.
    private let mixer = Mixer()
    private let media = MediaFeature()
    private let shelf = ShelfFeature()
    /// Shelf files sent to Cloudflare R2, from each file's menu.
    private let r2 = R2Uploads()
    private let clipboard = ClipboardFeature()
    private let capture = CaptureFeature()
    private let calendar: CalendarFeature
    /// The weather where you are, in Now.
    private let weather = WeatherFeature(locator: SystemWeatherLocator())
    /// The add field in Now's second row, which the plus and the body share.
    private let nowModel = NowModel()
    private let notes = NotesFeature()
    /// Notes taken out of the notch, in windows of their own.
    private lazy var pinnedNotes = PinnedNoteWindows(notes: notes)
    private let shortcuts = ShortcutsFeature()
    private let timer = TimerFeature()
    private let storage = StorageFeature()
    private let network = NetworkFeature()
    private let admin = SystemAdminFeature()
    private let performance = PerformanceFeature()
    private let monitors = MonitorsFeature()
    /// Window snapping and layouts: a Settings page and shortcuts, no tab.
    private let windows = WindowManager()
    /// Option-Tab between every window: a Settings page and a shortcut, no tab.
    private let windowSwitcher = WindowSwitcher()
    /// A search panel for apps and the actions below: a Settings page and a shortcut, no tab.
    private let commandBar = CommandBar()
    private lazy var features = FeatureHost(featureList)
    // System live activities, which belong to no tab.
    private let volume = VolumeMonitor()
    private let battery = BatteryMonitor()
    private let accessories = AccessoryMonitor()
    private let volumeKeys = VolumeKeyTap()
    /// Opens and closes the notch from any app.
    private let notchKey = HotKey()
    /// Escape, only while a notch the shortcut opened is still open.
    private let escapeKey = HotKey()
    /// Escape, only while a recording's countdown runs: it cancels the recording.
    private let recordingEscapeKey = HotKey()
    /// Starts a new note from any app, while Notes has it on.
    private let quickNoteKey = HotKey()
    /// Opens the Clipboard tab from any app, ready to search.
    private let clipboardKey = HotKey()
    /// Gives each app its own keyboard input source. Not a tab: it works while the notch is away.
    private let inputSwitch = InputSwitcher()

    override init() {
        calendar = CalendarFeature(eventStore: EventStore())
        super.init()
    }
    private var coordinator: PanelCoordinator?
    /// Show in Notch messages that arrived while launching, before there was a notch to show them.
    private var pendingMessages: [Activity] = []
    private var statusItem: StatusItemController?
    private let updater = Updater()
    private lazy var settings = SettingsWindowController(
        preferences: preferences,
        updater: updater,
        notchKey: notchKey,
        clipboardKey: clipboardKey,
        inputSwitch: inputSwitch,
        windows: windows,
        windowSwitcher: windowSwitcher,
        commandBar: commandBar,
        previewAnimation: { [weak self] in self?.coordinator?.previewAnimation() },
        featureSettings: { [unowned self] in self.settingsView(for: $0) })

    private var featureList: [any NotchFeature] {
        [
            media, shelf, clipboard, capture, calendar, notes, shortcuts, timer, storage, network, usage,
            agents, monitors, admin, performance, weather,
        ]
    }

    /// What the command bar can do, asked for each time it opens. This is the one list features join:
    /// add a line here to make an action searchable.
    private var commandActions: [CommandAction] {
        var list: [CommandAction] = []
        func add(
            _ id: String, _ title: String, _ area: String, _ symbol: String, _ keywords: String = "",
            shortcut: String? = nil, _ run: @escaping @MainActor () -> Void
        ) {
            list.append(
                CommandAction(
                    id: id, title: title, area: area, symbol: symbol, keywords: keywords, shortcut: shortcut, run: run))
        }
        for space in preferences.spaceSet.spaces {
            add(
                "space.\(space.rawValue)", "Open \(space.title)", "Notch", "rectangle.topthird.inset.filled",
                "space notch"
            ) {
                [weak self] in self?.coordinator?.open(space)
            }
        }
        for feature in preferences.enabledFeatures {
            add("tab.\(feature.rawValue)", "Open \(feature.title)", "Notch", feature.symbol, "tab notch") {
                [weak self] in self?.coordinator?.show(feature)
            }
        }
        if preferences.isEnabled(.capture) {
            for tool in CaptureFeature.Tool.allCases {
                add("capture.\(tool.rawValue)", tool.title, "Capture", tool.symbol, "capture screen") { [capture] in
                    capture.run(tool)
                }
            }
        }
        if preferences.isEnabled(.timer) {
            add(
                "awake", timer.keepsAwake ? "Let the Mac Sleep" : "Keep the Mac Awake", "Timer",
                "cup.and.saucer", "keep awake caffeinate coffee sleep"
            ) { [timer] in
                if timer.keepsAwake { timer.allowSleep() } else { timer.keepAwake(for: nil) }
            }
        }
        if preferences.isEnabled(.monitors) {
            add("sleepDisplays", "Sleep Displays", "Displays", "display", "screen off monitor") { [monitors] in
                monitors.sleepDisplays()
            }
        }
        if windows.isEnabled {
            for action in WindowAction.allCases {
                add(
                    "window.\(action.rawValue)", action.title, "Windows", "rectangle.split.2x1", "window snap move",
                    shortcut: action.shortcutText
                ) {
                    [windows] in windows.perform(action)
                }
            }
            for layout in windows.layouts {
                add("layout.\(layout.id)", "Apply \(layout.name)", "Windows", "rectangle.3.group", "layout") {
                    [windows] in windows.apply(layout)
                }
            }
        }
        // Notes are found here, since the notch lists them without a search field.
        if preferences.isEnabled(.notes) {
            for entry in notes.searchIndex() {
                add(
                    "note.\(entry.fileName)", entry.title, "Note", "note.text", entry.excerpt
                ) { [weak self] in self?.openNote(named: entry.fileName) }
            }
        }
        for page in SettingsSelection.Page.all {
            add("settings.\(page.title)", "\(page.title) Settings", "Settings", "gearshape", "preferences") {
                [weak self] in self?.settings.show(page)
            }
        }
        return list
    }

    private func featureView(for feature: FeatureID) -> AnyView {
        switch feature {
        case .media: return AnyView(EmptyView())  // Now draws it
        case .sound:
            return AnyView(SoundView(mixer: mixer, monitors: monitors))
        case .shelf:
            return AnyView(shelf.view)
        case .clipboard: return AnyView(clipboard.view)
        case .capture: return AnyView(capture.view)
        case .calendar, .weather: return AnyView(EmptyView())  // Now draws them
        case .notes: return AnyView(EmptyView())  // Now draws them
        case .shortcuts: return AnyView(shortcuts.view)
        case .timer: return AnyView(timer.view)
        case .storage: return AnyView(storage.view)
        case .network: return AnyView(network.view)
        case .usage, .agents: return AnyView(EmptyView())  // the Agents screen draws them
        case .monitors: return AnyView(monitors.view)
        case .admin:
            return AnyView(
                SystemScreen(
                    performance: preferences.isEnabled(.performance) ? performance : nil,
                    admin: preferences.isEnabled(.admin) ? admin : nil))
        case .performance: return AnyView(performance.view)
        }
    }

    /// The spaces that draw their whole body from the features that are on.
    private func screen(for space: SpaceID, enabled: Set<FeatureID>) -> AnyView? {
        switch space {
        case .tools:
            return AnyView(
                ToolsScreen(
                    capture: enabled.contains(.capture) ? capture : nil, timer: enabled.contains(.timer) ? timer : nil,
                    shortcuts: enabled.contains(.shortcuts) ? shortcuts : nil,
                    sleepDisplays: { [monitors] in monitors.sleepDisplays() }))
        case .agents:
            return AnyView(
                AgentsScreen(
                    agents: enabled.contains(.agents) ? agents : nil, usage: enabled.contains(.usage) ? usage : nil))
        case .mac:
            return AnyView(
                MacScreen(
                    performance: enabled.contains(.performance) ? performance : nil,
                    mixer: enabled.contains(.sound) ? mixer : nil,
                    monitors: enabled.contains(.monitors) ? monitors : nil,
                    admin: enabled.contains(.admin) ? admin : nil, enabled: enabled,
                    detail: { [unowned self] in featureView(for: $0) }))
        default:
            return nil
        }
    }

    /// Each tab's own settings, as the sections of its Settings page.
    private func settingsView(for feature: FeatureID) -> AnyView? {
        switch feature {
        case .media: return section(media.settingsView)
        case .sound:
            return section(mixer.settingsView)
        case .shelf:
            return AnyView(
                Group {
                    Section { shelf.settingsView }
                    Section("Upload to R2") { r2.settingsView }
                })
        case .clipboard: return section(clipboard.settingsView)
        case .capture: return section(capture.settingsView)
        case .calendar: return section(calendar.settingsView)
        case .weather: return nil
        case .shortcuts: return section(shortcuts.settingsView)
        case .notes: return section(notes.settingsView)
        case .network: return section(network.settingsView)
        case .timer, .storage: return nil
        case .usage:
            return AnyView(usage.settingsView)  // sections of its own
        case .agents:
            return section(agents.settingsView)
        case .monitors: return nil
        case .admin: return nil
        case .performance: return nil
        }
    }

    private func section(_ rows: some View) -> AnyView { AnyView(Section { rows }) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = .hiddenEditMenu()
        let content = NotchContent(
            feature: { [unowned self] in self.featureView(for: $0) },
            now: { [unowned self] in
                AnyView(
                    NowView(
                        media: preferences.isEnabled(.media) ? media : nil,
                        calendar: preferences.isEnabled(.calendar) ? calendar : nil,
                        notes: preferences.isEnabled(.notes) ? notes : nil,
                        weather: preferences.isEnabled(.weather) ? weather : nil,
                        model: nowModel, openNote: { [weak self] in self?.pinnedNotes.present($0.id) }))
            },
            badge: { [unowned self] in $0 == .agents ? agents.waitingCount : 0 },
            actions: { [unowned self] space, feature in
                if space == .now {
                    return AnyView(
                        NowActions(
                            timer: preferences.isEnabled(.timer) ? timer : nil, model: nowModel,
                            canAdd: preferences.isEnabled(.calendar) || preferences.isEnabled(.notes)))
                }
                switch (space, feature) {
                case (.shelf, _): return AnyView(shelf.headerActions)
                case (.clipboard, _): return AnyView(clipboard.headerActions)
                case (.agents, _): return preferences.isEnabled(.usage) ? AnyView(usage.actions) : AnyView(EmptyView())
                default: return AnyView(EmptyView())
                }
            },
            dropFiles: { [preferences, shelf] urls in preferences.isEnabled(.shelf) && shelf.add(urls) },
            openSettings: { [weak self] in self?.settings.show() },
            screen: { [unowned self] space, enabled in screen(for: space, enabled: enabled) },
            slot: { [unowned self] space in
                guard space == .now else { return AnyView(EmptyView()) }
                // An agent waiting for an answer comes first, then a meeting about to start, then the field.
                let agent =
                    preferences.isEnabled(.agents)
                    ? AgentRequestBar(agents: agents, open: { [weak self] in self?.coordinator?.open($0) })
                        .map { AnyView($0) }
                    : nil
                return AnyView(
                    NowSlot(
                        agent: agent, calendar: preferences.isEnabled(.calendar) ? calendar : nil,
                        notes: preferences.isEnabled(.notes) ? notes : nil, model: nowModel))
            },
            join: { [calendar] url in calendar.join(url: url) },
            recording: { [capture] control in capture.recorder.handle(control) },
            leading: { [unowned self] space in
                switch space {
                case .shelf: shelf.headerLeading()
                case .clipboard: clipboard.headerLeading()
                case .agents:
                    AnyView(
                        AgentsTitle(
                            agents: preferences.isEnabled(.agents) ? agents : nil,
                            usage: preferences.isEnabled(.usage) ? usage : nil))
                default: nil
                }
            },
            hasRow: { [unowned self] space in
                space.hasSecondRow(
                    shelfFilled: !shelf.items.isEmpty, clipboardHistory: clipboard.showsHistory,
                    agentsRow: preferences.isEnabled(.usage) || agents.waitingCount > 0)
            })
        let coordinator = PanelCoordinator(preferences: preferences, content: content)
        // Esc closes an open add field first, and the deck only when there is none.
        coordinator.takesEscape = { [nowModel, capture] in nowModel.escape() || capture.cancelRecordingCountdown() }
        coordinator.onNotchesChange = { [weak self] notches in
            guard let self else { return }
            features.update(notches: notches, enabled: Set(preferences.enabledFeatures))
            if !notches.contains(where: { $0.presentation.openSpace != nil }) { escapeKey.shortcut = nil }
        }
        notchKey.onPress = { [weak self, weak coordinator] in
            guard let self, coordinator?.toggleNotch() == true else { return }
            escapeKey.shortcut = .escape
        }
        escapeKey.onPress = { [weak coordinator] in coordinator?.escape() }
        clipboardKey.onPress = { [weak self, weak coordinator] in
            guard let self, coordinator?.toggle(.clipboard) == true else { return }
            clipboard.wantsSearch = true
        }
        clipboard.onActivity = { [weak coordinator] in coordinator?.broadcast(.activity($0)) }
        clipboard.onPicked = { [weak coordinator] in coordinator?.dismissAll() }
        media.onActivity = { [weak coordinator] in coordinator?.broadcast(.activity($0)) }
        media.onOngoing = { [weak coordinator] in coordinator?.setOngoing($0, for: .media) }
        shelf.onActivity = { [weak coordinator] in coordinator?.broadcast(.activity($0)) }
        shelf.onBegin = { [weak coordinator] in coordinator?.dismissAll() }
        shelf.uploads = r2
        shelf.addToNote = { [notes] text in notes.add(text) }
        r2.onActivity = { [weak coordinator] in coordinator?.broadcast(.activity($0)) }
        capture.onActivity = { [weak coordinator] in coordinator?.broadcast(.activity($0)) }
        capture.onScreenshot = { [preferences, clipboard] png in
            if preferences.isEnabled(.clipboard) { clipboard.addScreenshot(png: png) }
        }
        capture.onBegin = { [weak coordinator] in coordinator?.dismissAll() }
        // A recording shows in the closed notch with priority over music; its countdown ends on Escape.
        capture.recorder.onOngoing = { [weak coordinator] in coordinator?.setOngoing($0, for: .capture) }
        capture.recorder.onActivity = { [weak coordinator] in coordinator?.broadcast(.activity($0)) }
        capture.recorder.onCountdownChange = { [recordingEscapeKey] counting in
            recordingEscapeKey.shortcut = counting ? .escape : nil
        }
        recordingEscapeKey.onPress = { [capture] in capture.cancelRecordingCountdown() }
        capture.isEnabled = { [preferences] in preferences.isEnabled(.capture) }
        capture.addToShelf = { [preferences, shelf] urls in preferences.isEnabled(.shelf) && shelf.add(urls) }
        calendar.onActivity = { [weak coordinator] in coordinator?.broadcast(.activity($0)) }
        calendar.onOngoing = { [weak coordinator] in coordinator?.setOngoing($0, for: .calendar) }
        timer.onActivity = { [weak coordinator] in coordinator?.broadcast(.activity($0)) }
        timer.onOngoing = { [weak coordinator] in coordinator?.setOngoing($0, for: .timer) }
        timer.restoreAwake()
        network.onActivity = { [weak coordinator] in coordinator?.broadcast(.activity($0)) }
        network.onOngoing = { [weak coordinator] in coordinator?.setOngoing($0, for: .network) }
        shortcuts.onActivity = { [weak coordinator] in coordinator?.broadcast(.activity($0)) }
        admin.onActivity = { [weak coordinator] in coordinator?.broadcast(.activity($0)) }
        pinnedNotes.start()
        inputSwitch.resume()
        quickNoteKey.onPress = { [weak self] in self?.startQuickNote() }
        volume.onActivity = { [weak coordinator] in coordinator?.broadcast(.activity($0)) }
        battery.onActivity = { [weak coordinator] in coordinator?.broadcast(.activity($0)) }
        accessories.onActivity = { [weak coordinator] in coordinator?.broadcast(.activity($0)) }
        usage.onActivity = { [weak coordinator] in coordinator?.broadcast(.activity($0)) }
        usage.openSettings = { [weak self] in self?.settings.show(.space(.agents)) }
        agents.onActivity = { [weak coordinator] in coordinator?.broadcast(.activity($0)) }
        agents.onOngoing = { [weak coordinator] in coordinator?.setOngoing($0, for: .agents) }
        // A phone asking to send opens the notch on the shelf, where its request is.
        // Hovering the volume in the closed notch opens the Sound tab, where everything else is.
        volume.onActivity = { [weak coordinator, preferences] activity in
            var activity = activity
            if preferences.isEnabled(.sound) { activity.feature = .sound }
            coordinator?.broadcast(.activity(activity))
        }
        volumeKeys.onKey = { [volume] key, fine in
            switch key {
            case .up: volume.step(up: true, fine: fine)
            case .down: volume.step(up: false, fine: fine)
            case .mute: volume.toggleMute()
            }
        }
        coordinator.start()
        windows.activate()
        windowSwitcher.activate()
        commandBar.actions = { [unowned self] in self.commandActions }
        commandBar.activate()
        self.coordinator = coordinator
        pendingMessages.forEach(showInNotch)
        pendingMessages = []
        observeContinuously { [weak self] in self?.updateSystemActivities() }
        observeContinuously { [weak self] in
            guard let self else { return }
            notchKey.shortcut = preferences.notchShortcut
            clipboardKey.shortcut = preferences.isEnabled(.clipboard) ? preferences.clipboardShortcut : nil
        }
        // Accessibility access arrives while running; this is posted when it changes.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))  // trust updates just after the notification
                self?.updateSystemActivities()
            }
        }
        LegacyDefaults.removeMenuBarHider()  // before the menu bar item is made, so it takes its default place
        statusItem = StatusItemController(updater: updater) { [weak self] in self?.settings.show($0) }
    }

    /// Show in Notch links from scripts and other apps: topdeck://show?title=….
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let message = ShowInNotch.activity(from: url) else {
                Log.features.info("Ignored a link: \(url.absoluteString, privacy: .private)")
                continue
            }
            showInNotch(message)
        }
    }

    /// Shows a message from outside Topdeck, from a link or the Shortcuts action, as a live
    /// activity.
    func showInNotch(_ message: Activity) {
        guard let coordinator else {
            pendingMessages.append(message)
            return
        }
        coordinator.broadcast(.activity(message))
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stops every feature, including the media helper process and the camera.
        features.update(notches: [], enabled: [])
        capture.recorder.stopForQuit()  // so a recording's file is whole
        capture.saveVideoEdits()
        pinnedNotes.stop()
        commandBar.stop()
        inputSwitch.stop()
        mixer.isEnabled = false  // every app back to its own volume
        timer.allowSleep()
        volume.stop()
        battery.stop()
        accessories.stop()
        volumeKeys.stop()
    }

    /// A note found in the Command Bar: in a floating window, whether or not the notch is open.
    private func openNote(named fileName: String) {
        guard let id = notes.hold(fileName: fileName) else { return }
        pinnedNotes.present(id)
    }

    /// Opens the notch on Now with the add field set to Note, ready to type. Now gets a moment to come on
    /// screen before the field takes the keyboard.
    private func startQuickNote() {
        guard let coordinator, preferences.isEnabled(.notes) else { return }
        coordinator.show(.notes)
        nowModel.begin()
        nowModel.picked = .note
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.coordinator?.focusKeyboard()
        }
    }

    /// Runs each system activity's listener, and the quick note shortcut, only while Settings has it
    /// on. Replacing the volume display needs the volume activity and Accessibility access; without
    /// access the keys keep working as usual until access is granted.
    private func updateSystemActivities() {
        // Keep awake lives in the Timer tab: turning the tab off must not leave the Mac awake unseen.
        if !preferences.isEnabled(.timer) { timer.allowSleep() }
        // What moves while the Network tab is off isn't counted when it comes back.
        network.isEnabled = preferences.isEnabled(.network)
        // Apps keep the volumes set in the Sound tab only while it's on.
        mixer.isEnabled = preferences.isEnabled(.sound)
        preferences.showsVolume ? volume.start() : volume.stop()
        preferences.showsBattery ? battery.start() : battery.stop()
        preferences.showsAccessoryBattery ? accessories.start() : accessories.stop()
        if preferences.showsVolume, preferences.replacesVolumeDisplay {
            volumeKeys.start()
        } else {
            volumeKeys.stop()
        }
        quickNoteKey.shortcut = notes.quickNoteShortcut && preferences.isEnabled(.notes) ? .newNote : nil
    }
}
