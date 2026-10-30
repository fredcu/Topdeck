// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension ClipboardFeature {
    public var settingsView: some View { ClipboardSettings(clipboard: self) }
}

private struct ClipboardSettings: View {
    @Bindable var clipboard: ClipboardFeature
    @State private var trusted = VolumeKeyTap.isTrusted

    var body: some View {
        Group {
            // A closure, not a method reference: see the app's GeneralSettings.
            Toggle(
                isOn: Binding(
                    get: { clipboard.isRecording },
                    set: { $0 ? clipboard.startRecording() : clipboard.stopRecording() })
            ) {
                Text("Keep a history of what you copy")
                Text(
                    "Looks at the clipboard twice a second while it's on. Skips passwords, anything marked private, "
                        + "and copies from password managers. Kept on this Mac only.")
            }
            if clipboard.isRecording, clipboard.access != .allowed {
                LabeledContent("Paste from other apps") {
                    Button("Open Privacy Settings") { NSWorkspace.shared.open(.privacySettings("Privacy_Pasteboard")) }
                }
            }
            Toggle("Paste into the app in front", isOn: $clipboard.pastesAfterPicking)
            if clipboard.pastesAfterPicking, !trusted {
                LabeledContent("Accessibility") {
                    Button("Open Accessibility Settings") {
                        NSWorkspace.shared.open(.privacySettings("Privacy_Accessibility"))
                    }
                }
            }
            Toggle("Paste as plain text", isOn: $clipboard.pastesAsPlainText)
            Toggle("Remove tracking from links", isOn: $clipboard.cleansLinks)
            LabeledContent("Skip copies from") {
                Button("Add App\u{2026}", action: addApps)
            }
            ForEach(clipboard.ignoredApps, id: \.self) { ignoredApp($0) }
            LabeledContent(clipboard.items.count == 1 ? "1 item" : "\(clipboard.items.count) items") {
                Button("Clear History", role: .destructive, action: clipboard.clear)
                    .disabled(clipboard.items.allSatisfy(\.favorite))
            }
            .help("Favorites stay.")
        }
        .onAppear {
            clipboard.refreshAccess()
            trusted = VolumeKeyTap.isTrusted
        }
        .onChange(of: clipboard.pastesAfterPicking) { _, pastes in
            trusted = VolumeKeyTap.isTrusted
            if pastes, !trusted { VolumeKeyTap.requestTrust() }
        }
    }

    private func ignoredApp(_ bundleID: String) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name = url?.deletingPathExtension().lastPathComponent
        return LabeledContent {
            Button("Stop Skipping \(name ?? bundleID)", systemImage: "minus.circle") {
                clipboard.stopIgnoringApp(bundleID)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        } label: {
            Label {
                Text(name ?? bundleID)
            } icon: {
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: "app.dashed")
                }
            }
        }
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(filePath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier { clipboard.ignoreApp(bundleID) }
        }
    }
}
