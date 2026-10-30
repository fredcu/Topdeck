// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension InputSwitcher {
    /// Its settings, shown under the switch on its Settings page.
    public var settingsView: some View { InputSwitchSettings(switcher: self) }
}

/// Remembering, and the apps that always get one source.
struct InputSwitchSettings: View {
    @Bindable var switcher: InputSwitcher

    var body: some View {
        Group {
            Section {
                Toggle("Remember the input source in each app", isOn: $switcher.remembers)
                LabeledContent("Remembered sources") {
                    Button("Forget") { switcher.forgetRemembered() }
                        .disabled(!switcher.rules.hasRemembered)
                }
            }
            Section("Always Use") {
                ForEach(switcher.rules.fixedApps, id: \.bundleID) { app in
                    row(app)
                }
                Button("Add App\u{2026}", action: addApp)
            }
        }
        .onAppear(perform: switcher.refreshSources)
    }

    private func row(_ app: InputSwitchApp) -> some View {
        let fixed = switcher.rules.entries[app.bundleID]?.fixed
        let selection = Binding<String?>(get: { fixed }, set: { switcher.fix($0, for: app) })
        return HStack {
            Picker(selection: selection) {
                ForEach(switcher.sources) { source in
                    Text(source.name).tag(String?.some(source.id))
                }
                // A source turned off since: kept, and used again once it's back on.
                if let fixed, switcher.source(fixed) == nil {
                    Text(fixed).tag(String?.some(fixed))
                }
            } label: {
                Label {
                    Text(app.name)
                } icon: {
                    Image(nsImage: Self.icon(for: app.bundleID)).resizable().frame(width: 18, height: 18)
                }
            }
            Button {
                switcher.fix(nil, for: app)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(app.name)")
        }
    }

    /// Picks an app, which starts with the source on now.
    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
            let app = InputSwitchApp(bundleID: bundleID, name: (name as NSString).deletingPathExtension)
            switcher.fix(switcher.currentSourceID ?? switcher.sources.first?.id, for: app)
        }
    }

    private static func icon(for bundleID: String) -> NSImage {
        let workspace = NSWorkspace.shared
        guard let url = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
            return workspace.icon(for: .application)
        }
        return workspace.icon(forFile: url.path(percentEncoded: false))
    }
}
