// SPDX-License-Identifier: MIT
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import TopdeckCore
import TopdeckFeatures

/// Accessory apps have no app menu, so Settings opens from the menu bar item or the notch's gear
/// button, and activates the app while it's up. A sidebar of General and Notch, then a page for each
/// space and one for what works outside the notch; a space's page holds a section for each of its features.
@MainActor
final class SettingsWindowController {
    private let preferences: NotchPreferences
    private let updater: Updater
    private let notchKey: HotKey
    private let clipboardKey: HotKey
    private let inputSwitch: InputSwitcher
    private let windows: WindowManager
    private let windowSwitcher: WindowSwitcher
    private let commandBar: CommandBar
    private let previewAnimation: () -> Void
    private let featureSettings: (FeatureID) -> AnyView?
    private let selection = SettingsSelection()
    private var window: NSWindow?

    /// `featureSettings` supplies each feature's own settings, as the sections under its switch.
    init(
        preferences: NotchPreferences, updater: Updater, notchKey: HotKey, clipboardKey: HotKey,
        inputSwitch: InputSwitcher, windows: WindowManager, windowSwitcher: WindowSwitcher,
        commandBar: CommandBar,
        previewAnimation: @escaping () -> Void,
        featureSettings: @escaping (FeatureID) -> AnyView?
    ) {
        self.preferences = preferences
        self.updater = updater
        self.notchKey = notchKey
        self.clipboardKey = clipboardKey
        self.inputSwitch = inputSwitch
        self.windows = windows
        self.windowSwitcher = windowSwitcher
        self.commandBar = commandBar
        self.previewAnimation = previewAnimation
        self.featureSettings = featureSettings
    }

    /// Shows Settings, on `page` when one is given.
    func show(_ page: SettingsSelection.Page? = nil) {
        if let page { selection.page = page }
        if window == nil {
            let root = SettingsView(
                preferences: preferences, updater: updater, notchKey: notchKey, clipboardKey: clipboardKey,
                inputSwitch: inputSwitch, windows: windows, windowSwitcher: windowSwitcher,
                commandBar: commandBar,
                previewAnimation: previewAnimation, featureSettings: featureSettings, selection: selection)
            let host = NSHostingController(rootView: root)
            // The page's name goes in the toolbar, over a sidebar that runs to the top of the window.
            host.sceneBridgingOptions = [.title, .toolbars]
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.title = selection.page.title  // SwiftUI brings the title over when the page changes
            window.isReleasedWhenClosed = false
            window.setContentSize(SettingsView.size)
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Which Settings page is showing, so the notch and the menu bar item can open a given one.
@MainActor
@Observable
final class SettingsSelection {
    enum Page: Hashable {
        case general, notch, about, shortcutsAndWindows
        case space(SpaceID)

        /// The sidebar's groups, top to bottom.
        static let spaces: [Self] = SpaceID.allCases.map { .space($0) }
        /// Every page, for the command bar.
        static let all: [Self] = [.general, .notch] + spaces + [.shortcutsAndWindows, .about]
    }
    var page = Page.general
}

struct SettingsView: View {
    static let size = CGSize(width: 820, height: 590)

    let preferences: NotchPreferences
    let updater: Updater
    let notchKey: HotKey
    let clipboardKey: HotKey
    let inputSwitch: InputSwitcher
    let windows: WindowManager
    let windowSwitcher: WindowSwitcher
    let commandBar: CommandBar
    let previewAnimation: () -> Void
    let featureSettings: (FeatureID) -> AnyView?
    @Bindable var selection: SettingsSelection

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.page) {
                SidebarRow(page: .general).tag(SettingsSelection.Page.general)
                SidebarRow(page: .notch).tag(SettingsSelection.Page.notch)
                Section("Spaces") {
                    ForEach(SettingsSelection.Page.spaces, id: \.self) { SidebarRow(page: $0).tag($0) }
                }
                Section { SidebarRow(page: .shortcutsAndWindows).tag(SettingsSelection.Page.shortcutsAndWindows) }
                Section { SidebarRow(page: .about).tag(SettingsSelection.Page.about) }
            }
            .frame(minWidth: 240)  // the column width modifier is ignored in a hosted split view
            .toolbar(removing: .sidebarToggle)
        } detail: {
            page
                .id(selection.page)  // each page opens scrolled to its top
                .navigationTitle(selection.page.title)
        }
        .frame(width: Self.size.width)
        .frame(minHeight: 460, idealHeight: Self.size.height)
    }

    @ViewBuilder private var page: some View {
        switch selection.page {
        case .general:
            GeneralPage(preferences: preferences, notchKey: notchKey, clipboardKey: clipboardKey)
        case .notch: NotchPage(preferences: preferences, previewAnimation: previewAnimation)
        case .space(let space):
            SpacePage(space: space, preferences: preferences, featureSettings: featureSettings)
        case .shortcutsAndWindows:
            ShortcutsAndWindowsPage(
                windows: windows, switcher: windowSwitcher, commandBar: commandBar, inputSwitch: inputSwitch)
        case .about: AboutSettings(updater: updater)
        }
    }
}

extension SettingsSelection.Page {
    var title: String {
        switch self {
        case .general: "General"
        case .notch: "Notch"
        case .about: "About"
        case .shortcutsAndWindows: "Shortcuts & Windows"
        case .space(let space): space.title
        }
    }

    /// Its sidebar symbol, in the system's plain style.
    fileprivate var symbol: String {
        switch self {
        case .general: "gearshape"
        case .notch: "display"
        case .about: "info.circle"
        case .shortcutsAndWindows: "command"
        case .space(let space):
            switch space {
            case .now: "clock"
            case .shelf: "tray.full"
            case .clipboard: "list.clipboard"
            case .agents: "terminal"
            case .mac: "cpu"
            case .tools: "camera.viewfinder"
            }
        }
    }
}

/// A page in the sidebar: its symbol and name, and "Off" for a feature that's turned off.
private struct SidebarRow: View {
    let page: SettingsSelection.Page
    var off = false

    var body: some View {
        HStack {
            Label(page.title, systemImage: page.symbol)
            Spacer(minLength: 4)
            if off { Text("Off").foregroundStyle(.secondary) }
        }
    }
}

/// A page: its switch when it has one, then its settings in groups.
private struct SettingsPage<Content: View>: View {
    let title: String
    var isOn: Binding<Bool>?
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            if let isOn {
                Section { Toggle(title, isOn: isOn).font(.headline) }
            }
            content
        }
        .formStyle(.grouped)
    }
}

/// A space's page: for each feature the space owns, its switch, then its own settings while it's on.
private struct SpacePage: View {
    let space: SpaceID
    let preferences: NotchPreferences
    let featureSettings: (FeatureID) -> AnyView?

    var body: some View {
        Form {
            ForEach(space.features.filter { $0.home == space && preferences.available.contains($0) }, id: \.self) {
                feature in
                // A closure, not a method reference: see GeneralPage.
                let isOn = Binding(
                    get: { preferences.isEnabled(feature) }, set: { preferences.setEnabled(feature, $0) })
                Section {
                    Toggle(isOn: isOn) { Label(feature.title, systemImage: feature.symbol) }.font(.headline)
                }
                if preferences.isEnabled(feature), let settings = featureSettings(feature) { settings }
            }
        }
        .formStyle(.grouped)
    }
}

/// Everything that works outside the notch, in one page: for each of Windows, Window Switcher, Command Bar and
/// Input Sources its switch and the way to start it, then its settings while it's on. The way to start is
/// shown because none of these can be seen otherwise.
private struct ShortcutsAndWindowsPage: View {
    @Bindable var windows: WindowManager
    @Bindable var switcher: WindowSwitcher
    @Bindable var commandBar: CommandBar
    @Bindable var inputSwitch: InputSwitcher

    var body: some View {
        Form {
            Section("Windows") {
                Toggle("Windows", isOn: $windows.isEnabled).font(.headline)
                Trigger {
                    Text(windows.snapsOnDrag ? "Drag a window to a screen edge" : "Press a shortcut below")
                        .foregroundStyle(.secondary)
                }
            }
            if windows.isEnabled { windows.settingsView }
            Section("Window Switcher") {
                Toggle("Window Switcher", isOn: $switcher.isEnabled).font(.headline)
                Trigger { KeyCaps(shortcut: { switcher.shortcutText }) }
            }
            if switcher.isEnabled { switcher.settingsView }
            Section("Command Bar") {
                Toggle("Command Bar", isOn: $commandBar.isEnabled).font(.headline)
                Trigger { KeyCaps(shortcut: { commandBar.shortcutText }) }
            }
            if commandBar.isEnabled { commandBar.settingsView }
            Section("Input Sources") {
                Toggle("Input Sources", isOn: $inputSwitch.isEnabled).font(.headline)
                Trigger { Text("Switches by itself when you change apps").foregroundStyle(.secondary) }
            }
            if inputSwitch.isEnabled { inputSwitch.settingsView }
        }
        .formStyle(.grouped)
    }
}

/// The row that says how a feature is started.
private struct Trigger<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LabeledContent("Start it") { content }
    }
}

/// A shortcut as key caps, one for each modifier and one for the key, following the Recorder below it.
private struct KeyCaps: View {
    let shortcut: () -> String?
    @State private var text: String?

    var body: some View {
        HStack(spacing: 4) {
            if let text, !text.isEmpty {
                ForEach(Array(Self.keys(text).enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .padding(.horizontal, 6)
                        .frame(minWidth: 24, minHeight: 22)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            } else {
                Text("Not set").foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text ?? "Not set")
        .onAppear { text = shortcut() }
        .onReceive(
            NotificationCenter.default.publisher(for: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"))
        ) { _ in text = shortcut() }
    }

    /// Modifier symbols one by one, then the key whole ("Space", "\u{21E5}").
    static func keys(_ description: String) -> [String] {
        let modifiers = Set("\u{2303}\u{2325}\u{21E7}\u{2318}")
        let lead = description.prefix { modifiers.contains($0) }
        let key = description.dropFirst(lead.count)
        return lead.map(String.init) + (key.isEmpty ? [] : [String(key)])
    }
}

/// Launch, the shortcuts, which spaces the deck shows and in what order, and the two permissions.
private struct GeneralPage: View {
    @Bindable var preferences: NotchPreferences
    let notchKey: HotKey
    let clipboardKey: HotKey
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var confirmsReset = false
    @State private var accessibility = VolumeKeyTap.isTrusted
    @State private var screenRecording = CGPreflightScreenCaptureAccess()

    var body: some View {
        SettingsPage(title: SettingsSelection.Page.general.title) {
            Section {
                // A closure, not a method reference: converting the method to Binding's isolated
                // setter type crashes the Swift 6.3 compiler in IRGen.
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                shortcutRow("Open the notch", $preferences.notchShortcut, notchKey)
                if preferences.isEnabled(.clipboard) {
                    shortcutRow("Search the clipboard", $preferences.clipboardShortcut, clipboardKey)
                }
                Toggle("Show on all displays", isOn: $preferences.showOnAllDisplays)
            }
            Section("Spaces") {
                ForEach(Array(preferences.spaceOrder.enumerated()), id: \.element) { index, space in
                    spaceRow(space, index)
                }
            }
            Section {
                LabeledContent("Accessibility") {
                    if accessibility {
                        Label("Allowed", systemImage: "checkmark").foregroundStyle(.green)
                    } else {
                        Button("Continue", action: VolumeKeyTap.requestTrust)  // not "Allow": see AccessRow
                    }
                }
                LabeledContent("Screen Recording") {
                    if screenRecording {
                        Label("Allowed", systemImage: "checkmark").foregroundStyle(.green)
                    } else {
                        Button("Continue") {
                            CGRequestScreenCaptureAccess()
                            NSWorkspace.shared.open(.privacySettings("Privacy_ScreenCapture"))
                        }
                    }
                }
            }
            Section {
                LabeledContent("Reset to defaults") {
                    Button("Reset\u{2026}", role: .destructive) { confirmsReset = true }
                }
                .confirmationDialog("Reset Topdeck's settings?", isPresented: $confirmsReset) {
                    Button("Reset to Defaults", role: .destructive) { preferences.reset() }
                } message: {
                    Text("Every space comes back in its first place, with the original shortcuts and look.")
                }
            }
        }
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func refreshPermissions() {
        accessibility = VolumeKeyTap.isTrusted
        screenRecording = CGPreflightScreenCaptureAccess()
    }

    /// A shortcut and its recorder, or that another app already has it.
    private func shortcutRow(_ title: String, _ shortcut: Binding<KeyShortcut?>, _ hotKey: HotKey) -> some View {
        LabeledContent {
            ShortcutRecorder(shortcut: shortcut, hotKey: hotKey)
        } label: {
            Text(title)
            if !hotKey.isAvailable {
                Text("Another app already uses \(shortcut.wrappedValue?.display ?? "it"). Record another.")
                    .foregroundStyle(.red)
            }
        }
    }

    /// A space: shown or hidden, and moved earlier or later. A space whose features are all off stays
    /// out of the deck whatever is set here.
    private func spaceRow(_ space: SpaceID, _ index: Int) -> some View {
        HStack(spacing: 4) {
            Toggle(
                space.title,
                isOn: Binding(
                    get: { !preferences.hiddenSpaces.contains(space) },
                    set: { preferences.setSpace(space, hidden: !$0) })
            )
            .disabled(preferences.spaceSet.spaces == [space])  // the last one on show stays
            if !space.features.contains(where: preferences.isEnabled) {
                Text("Its features are off").foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                preferences.moveSpace(space, to: index - 1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(index == 0)
            .help("Move \(space.title) earlier")
            Button {
                preferences.moveSpace(space, to: index + 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(index == preferences.spaceOrder.count - 1)
            .help("Move \(space.title) later")
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// How the notch looks and where it shows, and the live activities that belong to no feature.
private struct NotchPage: View {
    @Bindable var preferences: NotchPreferences
    let previewAnimation: () -> Void
    @State private var screens = NSScreen.screens.filter { !$0.hasNotch }
    @State private var trusted = VolumeKeyTap.isTrusted

    var body: some View {
        SettingsPage(title: SettingsSelection.Page.notch.title) {
            Section {
                LabeledContent("Open and close") {
                    HStack {
                        Picker("Open and close", selection: $preferences.animationStyle) {
                            ForEach(NotchAnimationStyle.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button("Preview", action: previewAnimation)
                    }
                }
                LabeledContent("Open notch size") {
                    HStack {
                        Text("\(Int(preferences.expandedSize.width)) × \(Int(preferences.expandedSize.height))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Reset") { preferences.resizeExpanded(to: NotchPreferences.defaultExpandedSize) }
                            .disabled(preferences.expandedSize == NotchPreferences.defaultExpandedSize)
                    }
                }
            }
            Section("Displays Without a Notch") {
                ForEach(screens, id: \.uuid) { screen in
                    Picker(
                        screen.localizedName,
                        selection: Binding(
                            get: { preferences.notchlessStyle(for: screen.uuid) },
                            set: { preferences.setNotchlessStyle($0, for: screen.uuid) })
                    ) {
                        ForEach(NotchlessStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if screens.isEmpty {
                    Text("None connected").foregroundStyle(.secondary)
                }
            }
            Section("Volume") {
                Toggle("Show volume changes", isOn: $preferences.showsVolume)
                // A closure, not a method reference: see GeneralPage.
                let replaces = Binding(
                    get: { preferences.replacesVolumeDisplay }, set: { setReplacesVolumeDisplay($0) })
                Toggle("Replace the macOS volume display", isOn: replaces)
                    .disabled(!preferences.showsVolume)
                if preferences.replacesVolumeDisplay, !trusted {
                    LabeledContent("Accessibility") {
                        Button("Open Accessibility Settings") {
                            NSWorkspace.shared.open(.privacySettings("Privacy_Accessibility"))
                        }
                    }
                }
            }
            Section("Battery") {
                Toggle("Show charging and battery", isOn: $preferences.showsBattery)
                Toggle(
                    "Show a Bluetooth accessory's battery when it connects", isOn: $preferences.showsAccessoryBattery)
            }
        }
        .onAppear { trusted = VolumeKeyTap.isTrusted }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) {
            _ in screens = NSScreen.screens.filter { !$0.hasNotch }
        }
    }

    private func setReplacesVolumeDisplay(_ replaces: Bool) {
        preferences.replacesVolumeDisplay = replaces
        trusted = VolumeKeyTap.isTrusted
        if replaces, !trusted { VolumeKeyTap.requestTrust() }
    }
}

/// Click, then press the new shortcut; Escape cancels and Delete clears it. The shortcut stops
/// working while recording, so pressing the current one records it rather than opening the notch.
private struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut?
    let hotKey: HotKey
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(monitor != nil ? "Press the shortcut…" : shortcut?.display ?? "Record Shortcut") {
                monitor == nil ? record() : stop()
            }
            .help(monitor != nil ? "Escape cancels, Delete clears" : "Click, then press a new shortcut")
            if shortcut != nil, monitor == nil {
                Button("Clear") { shortcut = nil }
            }
        }
        .onDisappear(perform: stop)
    }

    private func record() {
        hotKey.isPaused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                let plain = event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift])
                switch Int(event.keyCode) {
                case kVK_Escape where plain:
                    stop()
                case kVK_Delete where plain, kVK_ForwardDelete where plain:
                    shortcut = nil
                    stop()
                default:
                    guard let recorded = KeyShortcut(event: event) else {
                        NSSound.beep()  // needs Command, Option, or Control
                        return
                    }
                    shortcut = recorded
                    stop()
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hotKey.isPaused = false
    }
}

/// The app, its version and updates, then asks for a star and for help, in the icon's coral and peach.
private struct AboutSettings: View {
    let updater: Updater

    static let coral = Color(red: 0.93, green: 0.30, blue: 0.24)
    static let peach = Color(red: 0.95, green: 0.50, blue: 0.22)

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .background {
                    Circle()
                        .fill(LinearGradient(colors: [Self.coral, Self.peach], startPoint: .top, endPoint: .bottom))
                        .blur(radius: 26)
                        .opacity(0.45)
                }
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Topdeck")
                    .font(.system(.title, design: .rounded).bold())
                Text("Version \(Updater.version)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            if updater.sourceDirectory != nil {
                Button(
                    updater.state == .updating ? "Updating…" : "Update Topdeck", action: updater.updateFromSource
                )
                .disabled(updater.state == .updating)
                if updater.state == .failed {
                    Button("The update failed. Show Log", action: updater.showLog).buttonStyle(.link)
                }
                Text("Rebuilds from this Mac's checkout and relaunches.").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Check for Updates…", action: updater.checkForUpdates)
            }
            AboutCard(url: Links.repository, glow: Self.coral) {
                HStack(spacing: 12) {
                    Image(systemName: "star.fill").font(.title)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Star Topdeck on GitHub").font(.headline)
                        Text("A star is how other Mac users find it.").font(.callout).opacity(0.9)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.callout.bold())
                }
                .foregroundStyle(.white)
                .padding(14)
                .background(
                    LinearGradient(colors: [Self.coral, Self.peach], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            HStack(spacing: 10) {
                AboutTile(
                    title: "Contribute", detail: "Good first issues", symbol: "chevron.left.forwardslash.chevron.right",
                    tint: .blue, url: Links.contributing)
                AboutTile(
                    title: "Report a Bug", detail: "Or ask for a feature", symbol: "ladybug.fill", tint: .orange,
                    url: Links.newIssue)
            }
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                Text("MIT licensed. Local-first: no accounts, no telemetry.").foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Link("Privacy", destination: Links.privacy)
                    Link("Acknowledgements", destination: Links.acknowledgements)
                }
            }
            .font(.caption)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}

/// One of the About tab's links: a card that lifts its glow under the pointer.
private struct AboutCard<Content: View>: View {
    let url: URL
    let glow: Color
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Link(destination: url) { content }
            .buttonStyle(.plain)
            .compositingGroup()  // one shadow for the card, not one per label
            .shadow(color: glow.opacity(hovering ? 0.45 : 0.15), radius: hovering ? 10 : 4, y: 2)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isLink)
    }
}

private struct AboutTile: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let url: URL

    var body: some View {
        AboutCard(url: url, glow: tint) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.15), in: Circle())
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.25)))
        }
    }
}
